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

local hex_digits = { x = 2, u = 4, U = 8 }

local function utf8_encode(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  elseif code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

-- Returns the first byte of the line terminator at or after `pos` (one past the
-- end of the source on the last line) and the position of its LF, if any.
local function line_end(source, pos)
  local newline = source:find("\n", pos)
  local stop = newline or #source + 1
  if newline and source:sub(newline - 1, newline - 1) == "\r" then
    stop = newline - 1
  end
  return stop, newline
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

  -- Reads the escape sequence at `pos`; returns its text and the next position.
  local function read_escape(pos, last)
    if pos + 1 > last then
      return nil
    end
    local escaped = char_at(source, pos + 1)
    if escapes[escaped] then
      return escapes[escaped], pos + 2
    end
    local count = hex_digits[escaped]
    if not count then
      fail(pos, "unknown escape sequence '\\" .. escaped .. "'")
    end
    local digits = source:sub(pos + 2, math.min(pos + 1 + count, last))
    if not digits:match("^" .. ("%x"):rep(count) .. "$") then
      fail(pos, "escape '\\" .. escaped .. "' needs " .. count .. " hexadecimal digits")
    end
    local code = tonumber(digits, 16)
    if code >= 0xD800 and code <= 0xDFFF or code > 0x10FFFF then
      fail(pos, "escape '\\" .. escaped .. digits .. "' is not a valid code point")
    end
    return utf8_encode(code), pos + 2 + count
  end

  local lex_token

  -- Reads the f-string field whose `{` is at `open`, up to byte `last`, for an
  -- f-string quoted with `quote`. Returns the position after its `}` and its
  -- tokens, which end with a FIELD_END token at the `}`.
  local function read_field(open, last, quote)
    local pos, nesting = open + 1, 0
    -- The scan advances lines for its diagnostics; the token pass below
    -- advances them again from the field's start.
    local open_line, open_line_start = line, line_start
    while true do
      if pos > last then
        line, line_start = open_line, open_line_start
        fail(open, "unterminated f-string field")
      end
      local c = source:sub(pos, pos)
      if c == "\n" then
        line, line_start = line + 1, pos + 1
      elseif c == "\\" then
        fail(pos, "f-string fields cannot contain a backslash")
      elseif c == "#" then
        fail(pos, "f-string fields cannot contain '#'")
      elseif c == quote then
        fail(pos, "f-string fields cannot contain the f-string's quote character")
      elseif c == "'" or c == '"' then
        -- A string in the other quote character may hold braces.
        local close = source:find(c, pos + 1, true)
        if not close or close > last or (source:find("\n", pos + 1, true) or close) < close then
          fail(pos, "unterminated string literal")
        end
        local inner = source:sub(pos + 1, close - 1)
        local bad = inner:find("[\\#" .. quote .. "]")
        if bad then
          fail(pos + bad, "f-string fields cannot contain '" .. inner:sub(bad, bad) .. "'")
        end
        pos = close
      elseif c == "(" or c == "[" or c == "{" then
        nesting = nesting + 1
      elseif c == ")" or c == "]" then
        nesting = nesting - 1
      elseif c == "}" then
        if nesting == 0 then
          break
        end
        nesting = nesting - 1
      elseif nesting == 0 and c == ":" then
        fail(pos, "format specifications are not supported")
      elseif nesting == 0 and c == "!" and source:sub(pos + 1, pos + 1) ~= "=" then
        fail(pos, "conversions are not supported")
      end
      pos = pos + 1
    end
    local close = pos
    line, line_start = open_line, open_line_start
    if source:sub(open + 1, close - 1):match("^[ \r\n]*$") then
      fail(open, "empty f-string field")
    end
    local outer = tokens
    tokens = {}
    pos = open + 1
    while pos < close do
      local c = source:sub(pos, pos)
      if c == "\n" then
        line, line_start = line + 1, pos + 1
        pos = pos + 1
      elseif c == "\r" then
        pos = pos + 1
      else
        pos = lex_token(pos, close - 1)
      end
    end
    add("FIELD_END", close, close)
    local field = tokens
    tokens = outer
    return close + 1, field
  end

  -- Reads the string whose opening quote is at `start`; `last` is the line's
  -- last byte. A triple-quoted string may continue onto later lines. An
  -- f-string's `f` is at `start - 1`.
  local function read_string(start, last, formatted)
    local first = formatted and start - 1 or start
    local opening = span_at(first, first)
    local quote = source:sub(start, start)
    local close = quote
    if source:sub(start, start + 2) == quote:rep(3) then
      close = quote:rep(3)
      last = #source
    end
    local parts, text = {}, {}
    local pos = start + #close
    while true do
      if pos > last then
        diag.error(opening, "unterminated string literal")
      end
      local c = source:sub(pos, pos)
      if source:sub(pos, pos + #close - 1) == close then
        break
      elseif c == "\\" then
        local escaped
        escaped, pos = read_escape(pos, last)
        if not escaped then
          diag.error(opening, "unterminated string literal")
        end
        text[#text + 1] = escaped
      elseif c == "\n" then
        text[#text + 1] = "\n"
        line, line_start = line + 1, pos + 1
        pos = pos + 1
      elseif c == "\r" then
        pos = pos + 1
      elseif formatted and c == "{" and source:sub(pos + 1, pos + 1) ~= "{" then
        parts[#parts + 1] = table.concat(text)
        text = {}
        pos, parts[#parts + 1] = read_field(pos, last, quote)
      elseif formatted and (c == "{" or c == "}") then
        if source:sub(pos + 1, pos + 1) ~= c then
          fail(pos, "single '}' is not allowed in an f-string")
        end
        text[#text + 1] = c
        pos = pos + 2
      else
        text[#text + 1] = c
        pos = pos + 1
      end
    end
    local token_span = span.new(opening.line, opening.col, first, pos + #close - 1)
    if formatted then
      parts[#parts + 1] = table.concat(text)
      tokens[#tokens + 1] = { kind = "FSTRING", value = parts, span = token_span }
    else
      tokens[#tokens + 1] = { kind = "STRING", value = table.concat(text), span = token_span }
    end
    return pos + #close
  end

  -- Reads one token starting at `pos`, which is at most `last`, and returns the
  -- next position, or nil at a comment.
  lex_token = function(pos, last)
    local c = source:sub(pos, pos)
    if c == " " then
      return pos + 1
    elseif c == "\t" then
      fail(pos, TABS)
    elseif c == "#" then
      return nil
    elseif c:match("[%a_]") then
      local word = source:match("^[%a_][%w_]*", pos)
      local after = source:sub(pos + 1, pos + 1)
      if word == "f" and (after == "'" or after == '"') then
        return read_string(pos + 1, last, true)
      elseif keywords[word] then
        add(word, pos, pos + #word - 1)
      else
        add("NAME", pos, pos + #word - 1, word)
      end
      return pos + #word
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
      return pos + #text
    elseif c == "'" or c == '"' then
      return read_string(pos, last, false)
    end
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
    return pos + #operator
  end

  -- Tokenizes from `pos` to the end of its line, which a triple-quoted string
  -- moves to a later line. Returns that line's `stop` and newline positions.
  local function lex_line(pos)
    local stop, newline = line_end(source, pos)
    while pos and pos < stop do
      local before = line
      pos = lex_token(pos, stop - 1)
      if pos and line ~= before then
        stop, newline = line_end(source, pos)
      end
    end
    return stop, newline
  end

  local pos = 1
  while pos <= #source do
    local stop, newline = line_end(source, pos)
    local count = #tokens
    if depth > 0 then
      stop, newline = lex_line(pos)
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
        stop, newline = lex_line(first)
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
