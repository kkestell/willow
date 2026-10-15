-- Runtime helpers, inlined by the emitter into every generated program. The
-- emitter defines __wlo_path before this text and assigns __wlo_sites and
-- __wlo_lines before calling __wlo_run.

local __wlo_source = debug.getinfo(1, "S").source
local __wlo_MAX_INT = 9007199254740991
local __wlo_MAX_FRAMES = 20

local function __wlo_fail(category, message, site)
  error({ category = category, message = message, location = __wlo_sites[site] }, 0)
end

-- Rejects results outside the integer range and normalizes -0.0 to 0.
local function __wlo_check(value, site)
  if value ~= value or value > __wlo_MAX_INT or value < -__wlo_MAX_INT then
    __wlo_fail("overflow", "integer overflow", site)
  end
  if value == 0 then
    return 0
  end
  return value
end

local function __wlo_add(a, b, site)
  return __wlo_check(a + b, site)
end

local function __wlo_sub(a, b, site)
  return __wlo_check(a - b, site)
end

local function __wlo_mul(a, b, site)
  return __wlo_check(a * b, site)
end

local function __wlo_neg(a, site)
  return __wlo_check(-a, site)
end

-- LuaJIT's dual-number mode multiplies integer-valued operands as integers,
-- so a zero product of opposite signs needs its sign restored.
local function __wlo_float_mul(a, b, site)
  local value = a * b
  if value == 0 and (a < 0 or 1 / a < 0) ~= (b < 0 or 1 / b < 0) then
    return -0.0
  end
  return value
end

-- Fails on a zero divisor, including -0.0.
local function __wlo_div(a, b, site)
  if b == 0 then
    __wlo_fail("division", "division by zero", site)
  end
  return a / b
end

-- Floor quotient and remainder by CPython's float_divmod. For integers in range
-- fmod and the subtraction are exact, so the results are too.
local function __wlo_divmod(a, b, site)
  if b == 0 then
    __wlo_fail("division", "division by zero", site)
  end
  local mod = math.fmod(a, b)
  local div = (a - mod) / b
  if mod ~= 0 then
    if (b < 0) ~= (mod < 0) then
      mod = mod + b
      div = div - 1
    end
  else
    mod = b < 0 and -0.0 or 0.0
  end
  if div ~= 0 then
    local floor = math.floor(div)
    if div - floor > 0.5 then
      floor = floor + 1
    end
    div = floor
  else
    -- 1 / q is negative when q is -0.0.
    local q = a / b
    div = (q < 0 or 1 / q < 0) and -0.0 or 0.0
  end
  return div, mod
end

local function __wlo_floordiv(a, b, site)
  local div = __wlo_divmod(a, b, site)
  return div
end

local function __wlo_mod(a, b, site)
  local _, mod = __wlo_divmod(a, b, site)
  return mod
end

local function __wlo_int_floordiv(a, b, site)
  local div = __wlo_divmod(a, b, site)
  if div == 0 then
    return 0
  end
  return div
end

local function __wlo_int_mod(a, b, site)
  local _, mod = __wlo_divmod(a, b, site)
  if mod == 0 then
    return 0
  end
  return mod
end

-- Truncates toward zero.
local function __wlo_int(x, site)
  local value = x < 0 and math.ceil(x) or math.floor(x)
  if value ~= value or value > __wlo_MAX_INT or value < -__wlo_MAX_INT then
    __wlo_fail("conversion", "cannot convert float to int", site)
  end
  if value == 0 then
    return 0
  end
  return value
end

-- Adds one to the last digit of a string of decimal digits.
local function __wlo_digits_up(digits)
  local i = #digits
  while i > 0 and digits:sub(i, i) == "9" do
    i = i - 1
  end
  if i == 0 then
    return "1" .. ("0"):rep(#digits)
  end
  return digits:sub(1, i - 1) .. string.char(digits:byte(i) + 1) .. ("0"):rep(#digits - i)
end

-- Formats a float as Python's repr does: the fewest digits that read back as
-- the same value, in scientific notation when the exponent is below -4 or at
-- least 16.
local function __wlo_format_float(x)
  if x ~= x then
    return "nan"
  end
  -- 1 / x is negative when x is -0.0.
  local sign = (x < 0 or 1 / x < 0) and "-" or ""
  x = math.abs(x)
  if x == math.huge then
    return sign .. "inf"
  end
  local digits, exponent
  for precision = 0, 16 do
    local text = string.format("%." .. precision .. "e", x)
    local first, rest, e = text:match("^(%d)%.?(%d*)e(.*)$")
    digits, exponent = first .. rest, tonumber(e)
    local value = tonumber(text)
    if value == x then
      break
    end
    -- Next to a power of two the rounding interval below x is half as wide as
    -- the one above, so the decimal above can read back when the nearest
    -- decimal, below x, does not.
    if value < x then
      local up = __wlo_digits_up(digits)
      local up_exponent = exponent + #up - #digits
      if tonumber(up:sub(1, 1) .. "." .. up:sub(2) .. "e" .. up_exponent) == x then
        digits, exponent = up, up_exponent
        break
      end
    end
  end
  digits = digits:gsub("0+$", "")
  if digits == "" then
    digits = "0"
  end
  local text
  if exponent < -4 or exponent >= 16 then
    text = digits:sub(1, 1) .. (#digits > 1 and "." .. digits:sub(2) or "")
      .. string.format("e%s%02d", exponent < 0 and "-" or "+", math.abs(exponent))
  elseif exponent < 0 then
    text = "0." .. ("0"):rep(-exponent - 1) .. digits
  else
    digits = digits .. ("0"):rep(exponent + 1 - #digits)
    local fraction = digits:sub(exponent + 2)
    text = digits:sub(1, exponent + 1) .. "." .. (fraction == "" and "0" or fraction)
  end
  return sign .. text
end

-- Flushes every line so a write failure is reported at the print that hit it.
local function __wlo_write(text, site)
  local ok, err = io.stdout:write(text, "\n")
  if ok then
    ok, err = io.stdout:flush()
  end
  if not ok then
    __wlo_fail("io", "cannot write output: " .. tostring(err), site)
  end
end

-- The text print writes for a value whose static type is not float.
local function __wlo_str(value)
  if value == nil then
    return "None"
  elseif value == true then
    return "True"
  elseif value == false then
    return "False"
  elseif type(value) == "number" then
    return string.format("%d", value)
  end
  return value
end

local function __wlo_str_float(value)
  if value == nil then
    return "None"
  end
  return __wlo_format_float(value)
end

local function __wlo_print(value, site)
  __wlo_write(__wlo_str(value), site)
end

local function __wlo_print_float(value, site)
  __wlo_write(__wlo_str_float(value), site)
end

-- Lists hold their elements at 1..n so that stored None (nil) counts.
local function __wlo_list(items, n)
  items.n = n
  return items
end

-- Dictionaries keep keys in insertion order. `positions` maps each key to its
-- index in `keys`, so a key with a None value is still present. `version`
-- changes when a key is added or removed.
local function __wlo_dict_set(dict, key, value, site)
  if not dict.positions[key] then
    local keys = dict.keys
    keys[#keys + 1] = key
    dict.positions[key] = #keys
    dict.version = dict.version + 1
  end
  dict.values[key] = value
end

-- `entries` holds each key followed by its value.
local function __wlo_dict(entries, n)
  local dict = { keys = {}, positions = {}, values = {}, version = 0 }
  for i = 1, 2 * n, 2 do
    __wlo_dict_set(dict, entries[i], entries[i + 1])
  end
  return dict
end

-- Every Willow string is valid UTF-8, so this matches one code point.
local __wlo_CODE_POINT = "[^\128-\191][\128-\191]*"

local function __wlo_code_points(text)
  local _, count = text:gsub(__wlo_CODE_POINT, "")
  return count
end

local function __wlo_len(value, site)
  if type(value) == "string" then
    return __wlo_code_points(value)
  end
  return value.n or #value.keys
end

local function __wlo_check_index(list, i, site)
  if i < 0 or i >= list.n then
    __wlo_fail("index", "list index out of range", site)
  end
end

local function __wlo_list_index(list, i, site)
  __wlo_check_index(list, i, site)
  return list[i + 1]
end

local function __wlo_list_set(list, i, value, site)
  __wlo_check_index(list, i, site)
  list[i + 1] = value
end

local function __wlo_list_append(list, value, site)
  local n = list.n + 1
  list[n] = value
  list.n = n
end

local function __wlo_list_pop(list, site)
  local n = list.n
  if n == 0 then
    __wlo_fail("index", "pop from empty list", site)
  end
  local value = list[n]
  list[n] = nil
  list.n = n - 1
  return value
end

local function __wlo_list_contains(list, value, site)
  for i = 1, list.n do
    if list[i] == value then
      return true
    end
  end
  return false
end

local function __wlo_dict_index(dict, key, site)
  if not dict.positions[key] then
    __wlo_fail("key", "key not found", site)
  end
  return dict.values[key]
end

local function __wlo_dict_get(dict, key, site)
  return dict.values[key]
end

local function __wlo_dict_pop(dict, key, site)
  local position = dict.positions[key]
  if not position then
    __wlo_fail("key", "key not found", site)
  end
  local value = dict.values[key]
  local keys = dict.keys
  table.remove(keys, position)
  for i = position, #keys do
    dict.positions[keys[i]] = i
  end
  dict.positions[key] = nil
  dict.values[key] = nil
  dict.version = dict.version + 1
  return value
end

local function __wlo_dict_contains(dict, key, site)
  return dict.positions[key] ~= nil
end

-- Iterators for `for` return true and the next item. A list's length is read
-- at each step, so appended elements are visited.
local function __wlo_list_items(list, site)
  local i = 0
  return function()
    if i < list.n then
      i = i + 1
      return true, list[i]
    end
  end
end

local function __wlo_dict_items(dict, site)
  local i, version = 0, dict.version
  return function()
    if dict.version ~= version then
      __wlo_fail("value", "dictionary changed size during iteration", site)
    end
    if i < #dict.keys then
      i = i + 1
      return true, dict.keys[i]
    end
  end
end

local function __wlo_str_items(text, site)
  local next_code_point = text:gmatch(__wlo_CODE_POINT)
  return function()
    local code_point = next_code_point()
    if code_point then
      return true, code_point
    end
  end
end

-- String helpers work on bytes: a valid UTF-8 needle only matches at code
-- point boundaries of a valid UTF-8 string.
local function __wlo_str_contains(text, sub, site)
  return text:find(sub, 1, true) ~= nil
end

local function __wlo_str_startswith(text, prefix, site)
  return text:sub(1, #prefix) == prefix
end

local function __wlo_str_endswith(text, suffix, site)
  return suffix == "" or text:sub(-#suffix) == suffix
end

local function __wlo_str_find(text, sub, site)
  local i = text:find(sub, 1, true)
  if not i then
    return -1
  end
  return __wlo_code_points(text:sub(1, i - 1))
end

local function __wlo_str_replace(text, old, new, site)
  local parts = {}
  if old == "" then
    parts[1] = new
    for code_point in text:gmatch(__wlo_CODE_POINT) do
      parts[#parts + 1] = code_point
      parts[#parts + 1] = new
    end
    return table.concat(parts)
  end
  local start = 1
  while true do
    local i, j = text:find(old, start, true)
    if not i then
      break
    end
    parts[#parts + 1] = text:sub(start, i - 1)
    parts[#parts + 1] = new
    start = j + 1
  end
  parts[#parts + 1] = text:sub(start)
  return table.concat(parts)
end

local function __wlo_str_strip(text, site)
  return text:match("^[ \t\n\v\f\r]*(.-)[ \t\n\v\f\r]*$")
end

local function __wlo_str_split(text, sep, site)
  if sep == "" then
    __wlo_fail("value", "empty separator", site)
  end
  local items = __wlo_list({}, 0)
  local start = 1
  while true do
    local i, j = text:find(sep, start, true)
    if not i then
      break
    end
    __wlo_list_append(items, text:sub(start, i - 1))
    start = j + 1
  end
  __wlo_list_append(items, text:sub(start))
  return items
end

local function __wlo_str_join(sep, items, site)
  return table.concat(items, sep, 1, items.n)
end

local function __wlo_range(start, stop, step, site)
  if step == 0 then
    __wlo_fail("value", "range step must not be zero", site)
  end
  local value, started = start, false
  return function()
    if started then
      value = value + step
    end
    started = true
    if step > 0 and value < stop or step < 0 and value > stop then
      return true, value
    end
  end
end

local function __wlo_where(location)
  return __wlo_path .. ":" .. location[1] .. ":" .. location[2]
end

-- Formats a failure with its Willow frames, innermost first. Only lines of
-- translated Willow code are in __wlo_lines, so runtime and wrapper frames
-- drop out.
local function __wlo_report(err)
  local frames = {}
  local level = 1
  local info = debug.getinfo(level, "Sl")
  while info do
    local frame = info.source == __wlo_source and __wlo_lines[info.currentline]
    if frame then
      frames[#frames + 1] = frame
    end
    level = level + 1
    info = debug.getinfo(level, "Sl")
  end
  if type(err) ~= "table" then
    local message = tostring(err):gsub("^.-:%d+: ", "")
    err = { category = "vm", message = message, location = frames[1] }
  end
  local lines = { __wlo_where(err.location) .. ": error: " .. err.message }
  for i, frame in ipairs(frames) do
    if i > __wlo_MAX_FRAMES then
      lines[#lines + 1] = "  ... " .. (#frames - __wlo_MAX_FRAMES) .. " more frames"
      break
    end
    lines[#lines + 1] = (i == 1 and "  in " or "  called from ") .. frame[3] .. " at " .. __wlo_where(frame)
  end
  return table.concat(lines, "\n")
end

local function __wlo_run(main)
  local ok, report = xpcall(main, __wlo_report)
  if not ok then
    io.stderr:write(report, "\n")
    os.exit(1)
  end
end
