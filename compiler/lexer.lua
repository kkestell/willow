-- Turns UTF-8 source text into a list of tokens with spans.
local diag = require("compiler.diag")
local span = require("compiler.span")

local M = {}

local function set(words)
  local result = {}
  for word in words:gmatch("%S+") do
    result[word] = true
  end
  return result
end

local keywords = set([[
False None True and as assert async await break case class continue def del
elif else except finally for from global if import in is lambda match nonlocal
not or pass raise return try type while with yield int float bool str list dict
]])

local operators = set("-> == != <= >= < > = + - * / // % | ( ) [ ] { } , : .")

local unsupported = set("**= //= <<= >>= ** << >> += -= *= /= %= &= |= ^= := & ^ ~")

local escapes = { ["\\"] = "\\", ["'"] = "'", ['"'] = '"', n = "\n", r = "\r", t = "\t" }

local MAX_INT = "9007199254740991"

local TABS = "tabs are not allowed outside strings and comments"

-- Well-formed UTF-8 sequences: no overlong forms, surrogates, or code points
-- above U+10FFFF.
local utf8_sequences = {
  "^[%z\1-\127]",
  "^[\194-\223][\128-\191]",
  "^\224[\160-\191][\128-\191]",
  "^[\225-\236\238\239][\128-\191][\128-\191]",
  "^\237[\128-\159][\128-\191]",
  "^\240[\144-\191][\128-\191][\128-\191]",
  "^[\241-\243][\128-\191][\128-\191][\128-\191]",
  "^\244[\128-\143][\128-\191][\128-\191]",
}

-- Returns the UTF-8 character starting at byte `pos`, or nil if it is malformed.
local function char_at(source, pos)
  for _, pattern in ipairs(utf8_sequences) do
    local char = source:match(pattern, pos)
    if char then
      return char
    end
  end
end

-- Code-point column of byte `pos` on the line starting at byte `line_start`.
local function column(source, line_start, pos)
  local _, continuation = source:sub(line_start, pos - 1):gsub("[\128-\191]", "")
  return pos - line_start + 1 - continuation
end

-- Rejects malformed UTF-8 and bare CRs anywhere in the file, including comments
-- and strings, so tokenizing can treat every CR as the start of a CRLF.
local function validate(source)
  local line, line_start, pos = 1, 1, 1
  while pos <= #source do
    local char = char_at(source, pos)
    local message
    if not char then
      message = "invalid UTF-8"
    elseif char == "\r" and source:sub(pos + 1, pos + 1) ~= "\n" then
      message = "bare carriage return; line endings must be LF or CRLF"
    end
    if message then
      diag.error(span.new(line, column(source, line_start, pos), pos, pos), message)
    end
    if char == "\n" then
      line, line_start = line + 1, pos + 1
    end
    pos = pos + #char
  end
end

function M.lex(source)
  validate(source)

  local tokens = {}
  local line, line_start = 1, 1
  local level, depth = 0, 0

  local function span_at(first, last)
    return span.new(line, column(source, line_start, first), first, last)
  end

  local function fail(pos, message)
    diag.error(span_at(pos, pos), message)
  end

  local function add(kind, first, last, value)
    tokens[#tokens + 1] = { kind = kind, value = value, span = span_at(first, last) }
  end

  -- Reads the string literal opening at `start`; `last` is the line's last byte.
  local function read_string(start, last)
    local quote = source:sub(start, start)
    local parts = {}
    local pos = start + 1
    while true do
      if pos > last then
        fail(start, "unterminated string literal")
      end
      local c = source:sub(pos, pos)
      if c == quote then
        add("STRING", start, pos, table.concat(parts))
        return pos + 1
      elseif c == "\\" then
        if pos + 1 > last then
          fail(start, "unterminated string literal")
        end
        local escaped = char_at(source, pos + 1)
        if not escapes[escaped] then
          fail(pos, "unknown escape sequence '\\" .. escaped .. "'")
        end
        parts[#parts + 1] = escapes[escaped]
        pos = pos + 2
      else
        parts[#parts + 1] = c
        pos = pos + 1
      end
    end
  end

  -- Tokenizes bytes `pos` through `last` of the current line.
  local function lex_line(pos, last)
    while pos <= last do
      local c = source:sub(pos, pos)
      if c == " " then
        pos = pos + 1
      elseif c == "\t" then
        fail(pos, TABS)
      elseif c == "#" then
        return
      elseif c:match("[%a_]") then
        local word = source:match("^[%a_][%w_]*", pos)
        if keywords[word] then
          add(word, pos, pos + #word - 1)
        else
          add("NAME", pos, pos + #word - 1, word)
        end
        pos = pos + #word
      elseif c:match("%d") then
        local digits = source:match("^%d+", pos)
        local text = source:match("^%d+%.%d+", pos) or digits
        text = text .. (source:match("^[eE][-+]?%d+", pos + #text) or "")
        local rest = source:match("^[%w_.]*", pos + #text)
        if rest ~= "" then
          fail(pos, "invalid number literal '" .. text .. rest .. "'")
        end
        local kind = text == digits and "integer" or "float"
        if #digits > 1 and digits:sub(1, 1) == "0" then
          fail(pos, kind .. " literal has leading zeros")
        end
        local value = tonumber(text)
        if kind == "float" then
          if value == math.huge then
            fail(pos, "float literal out of range")
          end
          add("FLOAT", pos, pos + #text - 1, value)
        else
          -- Compare digit strings so out-of-range values are never rounded.
          if #text > #MAX_INT or (#text == #MAX_INT and text > MAX_INT) then
            fail(pos, "integer literal out of range")
          end
          add("INT", pos, pos + #text - 1, value)
        end
        pos = pos + #text
      elseif c == "'" or c == '"' then
        pos = read_string(pos, last)
      else
        local operator
        for length = 3, 1, -1 do
          local text = source:sub(pos, pos + length - 1)
          if unsupported[text] then
            fail(pos, "unsupported operator '" .. text .. "'")
          end
          if operators[text] then
            operator = text
            break
          end
        end
        if not operator then
          fail(pos, "unexpected character '" .. char_at(source, pos) .. "'")
        end
        if operator == "(" or operator == "[" or operator == "{" then
          depth = depth + 1
        elseif (operator == ")" or operator == "]" or operator == "}") and depth > 0 then
          depth = depth - 1
        end
        add(operator, pos, pos + #operator - 1)
        pos = pos + #operator
      end
    end
  end

  local pos = 1
  while pos <= #source do
    local newline = source:find("\n", pos)
    -- `stop` is the first byte of the line terminator, or one past the end.
    local stop = newline or #source + 1
    if newline and source:sub(newline - 1, newline - 1) == "\r" then
      stop = newline - 1
    end
    local count = #tokens
    if depth > 0 then
      lex_line(pos, stop - 1)
    else
      local first = pos + #source:match("^ *", pos)
      local c = source:sub(first, first)
      if c == "\t" then
        fail(first, TABS)
      end
      -- Blank and comment-only lines produce no tokens at any width.
      if first ~= stop and c ~= "#" then
        local width = first - pos
        if width % 4 ~= 0 then
          fail(first, "indentation must be a multiple of four spaces")
        end
        local new_level = width / 4
        if new_level > level + 1 then
          fail(first, "unexpected indent")
        end
        if new_level > level then
          add("INDENT", first, first - 1)
        end
        for _ = new_level + 1, level do
          add("DEDENT", first, first - 1)
        end
        level = new_level
        lex_line(first, stop - 1)
      end
    end
    if depth == 0 and #tokens > count then
      add("NEWLINE", stop, newline or #source)
    end
    if newline then
      line, line_start, pos = line + 1, newline + 1, newline + 1
    else
      pos = #source + 1
    end
  end

  local eof = #source + 1
  -- A file that ends inside brackets gets no DEDENTs, so the parser reports
  -- the unclosed expression at end of file.
  if depth == 0 then
    for _ = 1, level do
      add("DEDENT", eof, eof - 1)
    end
  end
  add("EOF", eof, eof - 1)
  return tokens
end

return M
