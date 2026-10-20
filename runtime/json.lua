-- The json module, inlined after runtime/core.lua into programs that use it.
-- Json floats are boxed, since the union has both int and float members. The
-- helpers are the functions declared without `local`.

-- The text being parsed and the site of the parse call.
local __wlo_json_text, __wlo_json_site

-- Raises JsonError for `problem` at byte `pos` with its line and its column in
-- code points. Past the end of the text the problem is the end itself.
local function __wlo_json_error(problem, pos)
  local text = __wlo_json_text
  if pos > #text then
    problem = "unexpected end of input"
  end
  local before = text:sub(1, pos - 1)
  local _, newlines = before:gsub("\n", "")
  local line_start = before:match(".*\n()") or 1
  local column = __wlo_code_points(before:sub(line_start)) + 1
  __wlo_fail("json.JsonError", problem .. " at line " .. (newlines + 1) .. ", column " .. column, __wlo_json_site)
end

local function __wlo_json_space(pos)
  return __wlo_json_text:find("[^ \t\n\r]", pos) or #__wlo_json_text + 1
end

local function __wlo_json_word(pos, word, value)
  for i = 1, #word do
    if __wlo_json_text:byte(pos + i - 1) ~= word:byte(i) then
      __wlo_json_error("expected '" .. word .. "'", pos + i - 1)
    end
  end
  return value, pos + #word
end

-- Reads four hex digits at `pos`; `start` is the escape's backslash.
local function __wlo_json_hex4(pos, start)
  local text = __wlo_json_text
  for i = pos, pos + 3 do
    if i > #text then
      __wlo_json_error("", i)
    elseif not text:find("^%x", i) then
      __wlo_json_error("invalid escape", start)
    end
  end
  return tonumber(text:sub(pos, pos + 3), 16)
end

local __wlo_JSON_ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- The string whose opening quote is at `pos`, and the position after it.
local function __wlo_json_string(pos)
  local text = __wlo_json_text
  local parts = {}
  pos = pos + 1
  while true do
    local stop = text:find('[%z\1-\31"\\]', pos)
    if not stop then
      __wlo_json_error("", #text + 1)
    end
    parts[#parts + 1] = text:sub(pos, stop - 1)
    local c = text:sub(stop, stop)
    if c == '"' then
      return table.concat(parts), stop + 1
    elseif c ~= "\\" then
      __wlo_json_error("control character in string", stop)
    end
    local e = text:sub(stop + 1, stop + 1)
    pos = stop + 2
    if e == "u" then
      local code = __wlo_json_hex4(pos, stop)
      pos = pos + 4
      -- U+D800 through U+DFFF are surrogates; a high one (through U+DBFF) must
      -- pair with an escaped low one.
      if code >= 0xD800 and code <= 0xDFFF then
        if code > 0xDBFF or text:sub(pos, pos + 1) ~= "\\u" then
          __wlo_json_error("unpaired surrogate", stop)
        end
        local low = __wlo_json_hex4(pos + 2, pos)
        if low < 0xDC00 or low > 0xDFFF then
          __wlo_json_error("unpaired surrogate", stop)
        end
        code = 0x10000 + (code - 0xD800) * 1024 + (low - 0xDC00)
        pos = pos + 6
      end
      parts[#parts + 1] = __wlo_chr(code, __wlo_json_site)
    elseif __wlo_JSON_ESCAPES[e] then
      parts[#parts + 1] = __wlo_JSON_ESCAPES[e]
    elseif e == "" then
      __wlo_json_error("", stop + 1)
    else
      __wlo_json_error("invalid escape", stop)
    end
  end
end

-- A number with no fraction or exponent is an int, which must be in range; any
-- other number is a float.
local function __wlo_json_number(pos)
  local text = __wlo_json_text
  local int_end = text:match("^-?0()", pos) or text:match("^-?[1-9]%d*()", pos)
  if not int_end then
    __wlo_json_error("invalid number", pos)
  end
  local stop = int_end
  local fraction = text:match("^%.()", stop)
  if fraction then
    stop = text:match("^%d+()", fraction) or __wlo_json_error("invalid number", pos)
  end
  local exponent = text:match("^[eE][-+]?()", stop)
  if exponent then
    stop = text:match("^%d+()", exponent) or __wlo_json_error("invalid number", pos)
  end
  local number = text:sub(pos, stop - 1)
  if stop == int_end then
    local value = tonumber(number)
    if math.abs(value) > __wlo_MAX_INT then
      __wlo_json_error("integer out of range", pos)
    end
    return value == 0 and 0 or value, stop
  end
  return __wlo_box(__wlo_parse_float(number, __wlo_json_site)), stop
end

-- The value at or after `pos`, and the position after it.
local function __wlo_json_value(pos)
  local text = __wlo_json_text
  pos = __wlo_json_space(pos)
  local c = text:sub(pos, pos)
  if c == "{" then
    local dict = __wlo_dict({}, 0)
    pos = __wlo_json_space(pos + 1)
    if text:sub(pos, pos) == "}" then
      return dict, pos + 1
    end
    while true do
      pos = __wlo_json_space(pos)
      if text:sub(pos, pos) ~= '"' then
        __wlo_json_error("expected string", pos)
      end
      local key, value
      key, pos = __wlo_json_string(pos)
      pos = __wlo_json_space(pos)
      if text:sub(pos, pos) ~= ":" then
        __wlo_json_error("expected ':'", pos)
      end
      value, pos = __wlo_json_value(pos + 1)
      __wlo_dict_set(dict, key, value)
      pos = __wlo_json_space(pos)
      c = text:sub(pos, pos)
      if c == "}" then
        return dict, pos + 1
      elseif c ~= "," then
        __wlo_json_error("expected ',' or '}'", pos)
      end
      pos = pos + 1
    end
  elseif c == "[" then
    local items, n = {}, 0
    pos = __wlo_json_space(pos + 1)
    if text:sub(pos, pos) == "]" then
      return __wlo_list(items, 0), pos + 1
    end
    while true do
      n = n + 1
      items[n], pos = __wlo_json_value(pos)
      pos = __wlo_json_space(pos)
      c = text:sub(pos, pos)
      if c == "]" then
        return __wlo_list(items, n), pos + 1
      elseif c ~= "," then
        __wlo_json_error("expected ',' or ']'", pos)
      end
      pos = pos + 1
    end
  elseif c == '"' then
    return __wlo_json_string(pos)
  elseif c == "t" then
    return __wlo_json_word(pos, "true", true)
  elseif c == "f" then
    return __wlo_json_word(pos, "false", false)
  elseif c == "n" then
    return __wlo_json_word(pos, "null", nil)
  elseif c == "-" or c:find("^%d") then
    return __wlo_json_number(pos)
  end
  __wlo_json_error("expected value", pos)
end

function __wlo_json_parse(text, site)
  __wlo_json_text, __wlo_json_site = text, site
  local value, pos = __wlo_json_value(1)
  pos = __wlo_json_space(pos)
  if pos <= #text then
    __wlo_json_error("unexpected text after value", pos)
  end
  return value
end

local __wlo_JSON_QUOTES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
for code = 0, 31 do
  local c = string.char(code)
  __wlo_JSON_QUOTES[c] = __wlo_JSON_QUOTES[c] or string.format("\\u%04x", code)
end

local function __wlo_json_quote(text)
  return '"' .. text:gsub('[%z\1-\31"\\]', __wlo_JSON_QUOTES) .. '"'
end

local function __wlo_json_write(value, out, site)
  if value == nil then
    out[#out + 1] = "null"
  elseif type(value) == "boolean" then
    out[#out + 1] = tostring(value)
  elseif type(value) == "number" then
    out[#out + 1] = string.format("%d", value)
  elseif type(value) == "string" then
    out[#out + 1] = __wlo_json_quote(value)
  elseif value.__wlo_float ~= nil then
    local x = value.__wlo_float
    -- Infinities and NaN give NaN here.
    if x - x ~= 0 then
      __wlo_fail("json.JsonError", "cannot encode " .. __wlo_format_float(x), site)
    end
    out[#out + 1] = __wlo_format_float(x)
  elseif value.n then
    out[#out + 1] = "["
    for i = 1, value.n do
      if i > 1 then
        out[#out + 1] = ","
      end
      __wlo_json_write(value[i], out, site)
    end
    out[#out + 1] = "]"
  else
    out[#out + 1] = "{"
    for i, key in ipairs(value.keys) do
      if i > 1 then
        out[#out + 1] = ","
      end
      out[#out + 1] = __wlo_json_quote(key) .. ":"
      __wlo_json_write(value.values[key], out, site)
    end
    out[#out + 1] = "}"
  end
end

function __wlo_json_dump(value, site)
  local out = {}
  __wlo_json_write(value, out, site)
  return table.concat(out)
end
