-- Runtime helpers, inlined by the emitter into every generated program. The
-- emitter declares __wlo_paths, __wlo_sites, and __wlo_lines before this text
-- and assigns them before calling __wlo_run.

local __wlo_ffi = require("ffi")
local __wlo_tobit = require("bit").tobit
local __wlo_table_new = require("table.new")
-- Library functions the hot helpers call, bound once so a trace needs no guards
-- on the global and library tables. The sqrt helper ignores its site argument.
local __wlo_floor, __wlo_ceil, __wlo_sqrt = math.floor, math.ceil, math.sqrt
local __wlo_min, __wlo_max, __wlo_type = math.min, math.max, type
__wlo_ffi.cdef([[
typedef struct { int64_t sec; long nsec; } __wlo_timespec_t;
int snprintf(char *, size_t, const char *, ...);
void *__wlo_c_signal(int signal, void *handler) __asm__("signal");
int __wlo_c_clock_gettime(int clock, __wlo_timespec_t *time) __asm__("clock_gettime");
]])

local __wlo_source = debug.getinfo(1, "S").source
local __wlo_MAX_INT = 9007199254740991
local __wlo_MAX_FRAMES = 20
local __wlo_argv
-- Where the running task was started, set by the event loop; nil outside a
-- task group's tasks.
local __wlo_task_location

-- The Willow frames on the stack, innermost first. Only lines of translated
-- Willow code are in __wlo_lines, so runtime and wrapper frames drop out. A
-- task's frames end at its first frame, and `task` records where it started.
local function __wlo_frames()
  local frames = { task = __wlo_task_location }
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
  return frames
end

-- An exception is a record table with __wlo_class; raising records where it
-- happened. A host failure has no __wlo_class and cannot be caught.
local function __wlo_raise(exception, site)
  exception.__wlo_location = __wlo_sites[site]
  exception.__wlo_frames = __wlo_frames()
  error(exception, 0)
end

local function __wlo_reraise(exception, site)
  error(exception, 0)
end

local function __wlo_fail(class, message, site)
  __wlo_raise({ __wlo_class = class, message = message }, site)
end

local function __wlo_assert_fail(message, site)
  __wlo_fail("AssertionError", message, site)
end

local function __wlo_host_fail(message, site)
  error({ message = message, __wlo_location = __wlo_sites[site], __wlo_frames = __wlo_frames() }, 0)
end

-- Raises ValueError for a path the host would silently truncate.
local function __wlo_check_path(path, site)
  if path:find("\0", 1, true) then
    __wlo_fail("ValueError", "path contains a NUL character", site)
  end
end

-- io.open and os.rename report "<path>: <reason>"; returns the reason.
local function __wlo_open_reason(err, path)
  return err:sub(#path + 3)
end

-- A timeout is None or finite and positive.
local function __wlo_check_timeout(timeout, site)
  if timeout ~= nil and not (timeout > 0 and timeout < math.huge) then
    __wlo_fail("ValueError", "timeout must be finite and positive", site)
  end
end

local __wlo_CLOCK_MONOTONIC = __wlo_ffi.os == "OSX" and 6 or 1

-- Seconds on `clock`, a clock_gettime clock id.
local function __wlo_clock(clock)
  local now = __wlo_ffi.new("__wlo_timespec_t")
  __wlo_ffi.C.__wlo_c_clock_gettime(clock, now)
  return tonumber(now.sec) + tonumber(now.nsec) / 1e9
end

-- The xpcall message handler. It runs where the error happened, so a raw VM
-- error such as stack overflow gets the frames active at that point.
local function __wlo_catch(err)
  if type(err) ~= "table" then
    local frames = __wlo_frames()
    local message = tostring(err):gsub("^.-:%d+: ", "")
    err = { message = message, __wlo_location = frames[1], __wlo_frames = frames }
  end
  return err
end

-- Closing a generator raises this at its suspended `yield`. Protected blocks
-- run their `finally` clauses but no `except` handlers for it, and the
-- generator's coroutine catches it.
local __wlo_cancel = {}

-- Runs a protected block. Returns the block's departure code and value,
-- "raise" and the exception, or "cancel"; host failures propagate.
local function __wlo_try(body)
  local ok, code, value = xpcall(body, __wlo_catch)
  if ok then
    return code, value
  end
  if code == __wlo_cancel then
    return "cancel", code
  elseif not code.__wlo_class then
    error(code, 0)
  end
  return "raise", code
end

-- Rejects results outside the integer range. tobit(value) == value holds for
-- every int32 value, which LuaJIT's JIT folds away, so only larger results
-- reach the range test. The caller normalizes -0.0: tobit passes it through.
local function __wlo_check(value, site)
  if __wlo_tobit(value) ~= value
    and (value ~= value or value > __wlo_MAX_INT or value < -__wlo_MAX_INT) then
    __wlo_fail("OverflowError", "integer overflow", site)
  end
  return value
end

-- a + b and a - b of integers are never -0.0.
local function __wlo_add(a, b, site)
  return __wlo_check(a + b, site)
end

local function __wlo_sub(a, b, site)
  return __wlo_check(a - b, site)
end

-- Products and negations of zero can be -0.0, which becomes 0.
local function __wlo_mul(a, b, site)
  local value = a * b
  if value == 0 then
    return 0
  end
  return __wlo_check(value, site)
end

local function __wlo_neg(a, site)
  local value = -a
  if value == 0 then
    return 0
  end
  return __wlo_check(value, site)
end

-- LuaJIT's dual-number mode multiplies integer-valued operands as integers, so
-- `0 * -5` would give 0 instead of -0.0. Adding -0.0 first makes each operand a
-- double with the same value and sign (an integer 0 becomes +0.0), so the
-- multiply is IEEE's.
local function __wlo_float_mul(a, b, site)
  return (a + -0.0) * (b + -0.0)
end

-- Fails on a zero divisor, including -0.0.
local function __wlo_div(a, b, site)
  if b == 0 then
    __wlo_fail("ZeroDivisionError", "division by zero", site)
  end
  return a / b
end

-- Floor quotient and remainder by CPython's float_divmod.
local function __wlo_divmod(a, b, site)
  if b == 0 then
    __wlo_fail("ZeroDivisionError", "division by zero", site)
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
    local floor = __wlo_floor(div)
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

-- Integer `//` and `%` skip __wlo_divmod in the common case: LuaJIT's compiler
-- cannot trace math.fmod, so it would break the trace at every division. When
-- |div * b| <= 2^52, a / b cannot round past an integer and div * b is exact,
-- so math.floor(a / b) and a - div * b are exactly CPython's results; larger
-- magnitudes, where that can fail, take __wlo_divmod. An int32 `a` never needs
-- it: |div * b| <= |a| + |b|, and for |b| >= 2^31 the quotient is within 1 of
-- zero, so the floor is exact and a - div * b is an exact result below |b|.
local __wlo_LIMIT = 4503599627370496

local function __wlo_floordiv(a, b, site)
  local div = __wlo_divmod(a, b, site)
  return div
end

local function __wlo_mod(a, b, site)
  local _, mod = __wlo_divmod(a, b, site)
  return mod
end

local function __wlo_int_floordiv(a, b, site)
  if b == 0 then
    __wlo_fail("ZeroDivisionError", "division by zero", site)
  end
  local div = __wlo_floor(a / b)
  if __wlo_tobit(a) ~= a then
    local p = div * b
    if p > __wlo_LIMIT or p < -__wlo_LIMIT then
      div = __wlo_divmod(a, b, site)
    end
  end
  if div == 0 then
    return 0
  end
  return div
end

local function __wlo_int_mod(a, b, site)
  if b == 0 then
    __wlo_fail("ZeroDivisionError", "division by zero", site)
  end
  local div = __wlo_floor(a / b)
  local p = div * b
  local _, mod
  if __wlo_tobit(a) ~= a and (p > __wlo_LIMIT or p < -__wlo_LIMIT) then
    _, mod = __wlo_divmod(a, b, site)
  else
    mod = a - p
  end
  if mod == 0 then
    return 0
  end
  return mod
end

-- Truncates toward zero.
local function __wlo_int(x, site)
  local value = x < 0 and __wlo_ceil(x) or __wlo_floor(x)
  if value ~= value or value > __wlo_MAX_INT or value < -__wlo_MAX_INT then
    __wlo_fail("ValueError", "cannot convert float to int", site)
  end
  if value == 0 then
    return 0
  end
  return value
end

-- Without leading zeros, more than 16 digits is out of range, and tonumber is
-- exact up to 2^53 while rounding every larger 16-digit value to at least 2^53.
local function __wlo_parse_int(text, site)
  local sign, digits = text:match("^([-+]?)0*(%d+)$")
  if not digits or #digits > 16 or tonumber(digits) > __wlo_MAX_INT then
    __wlo_fail("ValueError", "cannot convert str to int", site)
  end
  local value = tonumber(digits)
  if sign == "-" and value ~= 0 then
    return -value
  end
  return value
end

-- LuaJIT's tonumber rounds decimal text to nearest as Python does, but rejects
-- exponents of 2^20 or more, so the exponent is clamped first. The clamp
-- changes no result unless the mantissa has hundreds of thousands of digits.
local function __wlo_parse_float(text, site)
  local sign, rest = text:match("^([-+]?)(.*)$")
  local word = rest:lower()
  if word == "inf" or word == "infinity" then
    return sign == "-" and -math.huge or math.huge
  elseif word == "nan" then
    return 0 / 0
  end
  local mantissa, exponent = rest:match("^(%d*%.?%d*)[eE]([-+]?%d+)$")
  if not mantissa then
    mantissa, exponent = rest:match("^%d*%.?%d*$"), "0"
  end
  if not mantissa or not mantissa:find("%d") then
    __wlo_fail("ValueError", "cannot convert str to float", site)
  end
  exponent = math.min(math.max(tonumber(exponent), -999999), 999999)
  return tonumber(string.format("%s%se%d", sign, mantissa, exponent))
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

-- Writes the strings `...` and flushes, so a write failure is reported at the
-- call that hit it.
local function __wlo_write(file, site, ...)
  local ok, err = file:write(...)
  if ok then
    ok, err = file:flush()
  end
  if not ok then
    __wlo_host_fail("cannot write output: " .. tostring(err), site)
  end
end

-- In a union with both int and float members, a float is boxed so that it
-- differs from an int. Elsewhere floats are plain numbers.
local function __wlo_box(value)
  if __wlo_type(value) == "number" then
    return { __wlo_float = value }
  end
  return value
end

local function __wlo_unbox(value)
  if __wlo_type(value) == "table" and value.__wlo_float ~= nil then
    return value.__wlo_float
  end
  return value
end

-- Equality of printable values, bytes, and tuples where floats may be boxed;
-- the only other tables are enum members, which are equal only to themselves.
-- Two tuples have the same arity, which their static types guarantee.
local function __wlo_equal(a, b)
  if __wlo_type(a) == "table" and __wlo_type(b) == "table" then
    if a.__wlo_octets ~= nil or b.__wlo_octets ~= nil then
      return a.__wlo_octets == b.__wlo_octets
    elseif a.__wlo_float ~= nil or b.__wlo_float ~= nil then
      return a.__wlo_float == b.__wlo_float
    elseif a.__wlo_tuple and b.__wlo_tuple then
      for i = 1, a.__wlo_tuple do
        if not __wlo_equal(a[i], b[i]) then
          return false
        end
      end
      return true
    end
  end
  return a == b
end

-- `a op b` for tuples of ordered positions: the first unequal position
-- decides, so a NaN there makes every comparison false.
local function __wlo_tuple_order(a, b, op)
  for i = 1, a.__wlo_tuple do
    local x, y = a[i], b[i]
    if __wlo_type(x) == "table" then
      if not __wlo_equal(x, y) then
        return __wlo_tuple_order(x, y, op)
      end
    elseif x ~= y then
      if op == "<" then
        return x < y
      elseif op == "<=" then
        return x <= y
      elseif op == ">" then
        return x > y
      end
      return x >= y
    end
  end
  return op == "<=" or op == ">="
end

-- A method bound to `receiver`, which was evaluated when the method was read.
local function __wlo_bind(receiver, method)
  return function(...)
    return method(receiver, ...)
  end
end

-- Converts `value` by `step`, which the compiler builds from the value's
-- static type: `float` boxes or unboxes a number, `[i]` converts tuple
-- position `i`, and `adapt(f, ...)` calls a function `f` for a callable type.
-- A converted tuple is a copy.
local function __wlo_convert(value, step)
  if __wlo_type(value) == "function" then
    local adapt = step.adapt
    if adapt then
      return function(...)
        return adapt(value, ...)
      end
    end
    return value
  elseif __wlo_type(value) == "table" and value.__wlo_tuple then
    local result = { __wlo_tuple = value.__wlo_tuple }
    for i = 1, value.__wlo_tuple do
      result[i] = value[i]
      if step[i] then
        result[i] = __wlo_convert(value[i], step[i])
      end
    end
    return result
  elseif step.float == "box" then
    return __wlo_box(value)
  elseif step.float == "unbox" then
    return __wlo_unbox(value)
  end
  return value
end

-- A protocol call passes this for an argument it leaves to the
-- implementation's default.
local __wlo_omitted = {}

-- The Lua iterator of a `for` loop over an iterable whose iterator is
-- `iterator`: each step calls `advance(iterator, site)`. Only StopIteration
-- from that call ends the loop; other errors propagate with the frames
-- `__wlo_catch` records where they happened.
local function __wlo_iterate(advance, iterator, site)
  return function()
    local ok, value = xpcall(advance, __wlo_catch, iterator, site)
    if ok then
      return true, value
    elseif value.__wlo_class == "StopIteration" then
      return nil
    end
    error(value, 0)
  end
end

-- `kind` is a Lua type name, "box", "bytes", "list", "dict", or "tuple".
local function __wlo_isinstance(value, kind)
  if type(value) ~= "table" then
    return type(value) == kind
  elseif value.__wlo_class or value.__wlo_enum then
    return false
  elseif value.__wlo_float ~= nil then
    return kind == "box"
  elseif value.__wlo_octets ~= nil then
    return kind == "bytes"
  elseif value.__wlo_tuple then
    return kind == "tuple"
  elseif value.n then
    return kind == "list"
  end
  -- A record has its class at [1]; a dict has no array part.
  return value[1] == nil and kind == "dict"
end

-- `name` is a class, an enum, or "Exception". Declared names are tested apart
-- from the kinds above, which a class or enum may share a name with.
local function __wlo_isinstance_type(value, name)
  if type(value) ~= "table" then
    return false
  end
  local class = value.__wlo_class or value.__wlo_enum
  if class == nil and not value.__wlo_tuple and not value.n then
    class = value[1]
  end
  return class == name or name == "Exception" and value.__wlo_class ~= nil
end

-- The text print writes for a value whose numbers are not unboxed floats.
local function __wlo_str(value)
  if value == nil then
    return "None"
  elseif value == true then
    return "True"
  elseif value == false then
    return "False"
  elseif type(value) == "number" then
    return string.format("%d", value)
  elseif type(value) == "table" then
    return value.__wlo_text or __wlo_format_float(value.__wlo_float)
  end
  return value
end

-- The text print writes for a value whose numbers are floats.
local function __wlo_str_float(value)
  if type(value) == "number" then
    return __wlo_format_float(value)
  end
  return __wlo_str(value)
end

local function __wlo_print(value, site)
  __wlo_write(io.stdout, site, __wlo_str(value), "\n")
end

local function __wlo_print_float(value, site)
  __wlo_write(io.stdout, site, __wlo_str_float(value), "\n")
end

local function __wlo_eprint(value, site)
  __wlo_write(io.stderr, site, __wlo_str(value), "\n")
end

local function __wlo_eprint_float(value, site)
  __wlo_write(io.stderr, site, __wlo_str_float(value), "\n")
end

-- Well-formed UTF-8 sequences: no overlong forms, surrogates, or code points
-- above U+10FFFF.
local __wlo_UTF8_SEQUENCES = {
  "^[%z\1-\127]",
  "^[\194-\223][\128-\191]",
  "^\224[\160-\191][\128-\191]",
  "^[\225-\236\238\239][\128-\191][\128-\191]",
  "^\237[\128-\159][\128-\191]",
  "^\240[\144-\191][\128-\191][\128-\191]",
  "^[\241-\243][\128-\191][\128-\191][\128-\191]",
  "^\244[\128-\143][\128-\191][\128-\191]",
}

-- The UTF-8 character starting at byte `pos` of `text`, or nil if it is
-- malformed.
local function __wlo_utf8_char(text, pos)
  for _, pattern in ipairs(__wlo_UTF8_SEQUENCES) do
    local char = text:match(pattern, pos)
    if char then
      return char
    end
  end
end

-- The code point of the UTF-8 character `char`.
local function __wlo_code_point(char)
  local value = char:byte(1)
  if #char > 1 then
    -- The lead byte of an n-byte sequence carries 7 - n value bits.
    value = value % 2 ^ (7 - #char)
    for i = 2, #char do
      value = value * 64 + char:byte(i) % 64
    end
  end
  return value
end

local function __wlo_valid_utf8(text)
  local pos = text:find("[\128-\255]")
  while pos do
    local char = __wlo_utf8_char(text, pos)
    if not char then
      return false
    end
    pos = text:find("[\128-\255]", pos + #char)
  end
  return true
end

local function __wlo_check_text(text, site)
  if not __wlo_valid_utf8(text) then
    __wlo_fail("ValueError", "invalid UTF-8", site)
  end
  return text
end

-- The files read through C stdio, which may hold buffered input that a child
-- process would not see.
local __wlo_read_files = setmetatable({}, { __mode = "k" })

-- The next line of `file` without its \n and a \r just before it, or nil at
-- end of input, and the read error. Reads with "*L" so that only a \r before
-- a \n is removed.
local function __wlo_read_line(file)
  __wlo_read_files[file] = true
  local line, err = file:read("*L")
  if line and line:sub(-1) == "\n" then
    line = line:sub(-2, -2) == "\r" and line:sub(1, -3) or line:sub(1, -2)
  end
  return line, err
end

local function __wlo_input(site)
  local line, err = __wlo_read_line(io.stdin)
  if err then
    __wlo_host_fail("cannot read input: " .. tostring(err), site)
  end
  return line and __wlo_check_text(line, site)
end

local function __wlo_read_file(path, site)
  __wlo_check_path(path, site)
  local file, err = io.open(path, "rb")
  if not file then
    __wlo_fail("OSError", "cannot read " .. path .. ": " .. __wlo_open_reason(err, path), site)
  end
  local text
  text, err = file:read("*a")
  file:close()
  if not text then
    __wlo_fail("OSError", "cannot read " .. path .. ": " .. tostring(err), site)
  end
  return __wlo_check_text(text, site)
end

local function __wlo_write_file(path, text, site)
  __wlo_check_path(path, site)
  local file, err = io.open(path, "wb")
  if not file then
    __wlo_fail("OSError", "cannot write " .. path .. ": " .. __wlo_open_reason(err, path), site)
  end
  local ok
  ok, err = file:write(text)
  if ok then
    ok, err = file:flush()
  end
  local closed, close_err = file:close()
  if ok and not closed then
    ok, err = closed, close_err
  end
  if not ok then
    __wlo_fail("OSError", "cannot write " .. path .. ": " .. tostring(err), site)
  end
end

-- Flushes the standard streams before the program ends. A failure is
-- reported as a failed write and ends the program with status 1.
local function __wlo_flush_streams()
  local ok, err = io.stdout:flush()
  if ok then
    ok, err = io.stderr:flush()
  end
  if not ok then
    io.stderr:write("error: cannot write output: ", tostring(err), "\n")
    os.exit(1)
  end
end

-- os.exit ends the process here, so no pending finally clause runs.
local function __wlo_exit(status, site)
  if status < 0 or status > 255 then
    __wlo_fail("ValueError", "exit status out of range", site)
  end
  __wlo_flush_streams()
  os.exit(status)
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
  if __wlo_type(value) == "string" then
    return __wlo_code_points(value)
  elseif value.__wlo_octets then
    return #value.__wlo_octets
  end
  return value.n or #value.keys
end

-- Adds `n` once to a negative index; nil when the result is outside 0..n-1.
local function __wlo_normalize_index(i, n)
  if i < 0 then
    i = i + n
  end
  if i >= 0 and i < n then
    return i
  end
end

-- Applies a slice's defaults, adds `n` once to negative bounds, and clamps
-- both to 0..n.
local function __wlo_slice_bounds(start, stop, n)
  start, stop = start or 0, stop or n
  if start < 0 then
    start = start + n
  end
  if stop < 0 then
    stop = stop + n
  end
  return __wlo_min(__wlo_max(start, 0), n), __wlo_min(__wlo_max(stop, 0), n)
end

local function __wlo_list_index(list, i, site)
  local j = __wlo_normalize_index(i, list.n)
  if not j then
    __wlo_fail("IndexError", "list index out of range", site)
  end
  return list[j + 1]
end

local function __wlo_list_set(list, i, value, site)
  local j = __wlo_normalize_index(i, list.n)
  if not j then
    __wlo_fail("IndexError", "list index out of range", site)
  end
  list[j + 1] = value
end

-- A new list sharing the elements of the slice.
local function __wlo_list_slice(list, start, stop, site)
  start, stop = __wlo_slice_bounds(start, stop, list.n)
  local n = __wlo_max(stop - start, 0)
  local items = __wlo_table_new(n, 1)
  for i = start + 1, stop do
    items[i - start] = list[i]
  end
  return __wlo_list(items, n)
end

-- Whether `value`, an int, float, str, or comparable tuple, holds NaN.
local function __wlo_has_nan(value)
  if type(value) == "table" then
    for i = 1, value.__wlo_tuple do
      if __wlo_has_nan(value[i]) then
        return true
      end
    end
    return false
  end
  return value ~= value
end

-- The elements of `list` in sorted order, by `key` when it is given. Keys are
-- evaluated once each, in input order, and an in-place sort fails if they
-- changed the list. Without NaN, keys are totally ordered; equal keys keep
-- their order in either direction. Nothing is reordered before every check
-- passes, since callers write the result back afterwards.
local function __wlo_sorted_values(list, reverse, key, in_place, site)
  local n, values, keys = list.n, {}, {}
  for i = 1, n do
    values[i] = list[i]
  end
  for i = 1, n do
    if key then
      keys[i] = key(values[i])
    else
      keys[i] = values[i]
    end
  end
  if in_place and key then
    local changed = list.n ~= n
    for i = 1, n do
      -- A NaN element is unequal to itself but unchanged.
      local a, b = list[i], values[i]
      changed = changed or a ~= b and (a == a or b == b)
    end
    if changed then
      __wlo_fail("RuntimeError", "list changed during sort", site)
    end
  end
  local order = {}
  for i = 1, n do
    if __wlo_has_nan(keys[i]) then
      __wlo_fail("ValueError", "cannot sort NaN", site)
    end
    order[i] = i
  end
  table.sort(order, function(i, j)
    local a, b = keys[i], keys[j]
    if a == b or type(a) == "table" and __wlo_equal(a, b) then
      return i < j
    elseif reverse then
      a, b = b, a
    end
    if type(a) == "table" then
      return __wlo_tuple_order(a, b, "<")
    end
    return a < b
  end)
  local sorted = {}
  for i, index in ipairs(order) do
    sorted[i] = values[index]
  end
  return sorted
end

local function __wlo_sorted(list, reverse, key, site)
  return __wlo_list(__wlo_sorted_values(list, reverse, key, false, site), list.n)
end

local function __wlo_list_sort(list, reverse, key, site)
  local values = __wlo_sorted_values(list, reverse, key, true, site)
  for i = 1, list.n do
    list[i] = values[i]
  end
end

-- Collects the items of a `for` iterator into a new list and sorts it.
local function __wlo_sort_items(step, reverse, key, site)
  local items, n = {}, 0
  for _, item in step do
    n = n + 1
    items[n] = item
  end
  return __wlo_list(__wlo_sorted_values(__wlo_list(items, n), reverse, key, false, site), n)
end

local function __wlo_list_append(list, value, site)
  local n = list.n + 1
  list[n] = value
  list.n = n
end

local function __wlo_list_pop(list, site)
  local n = list.n
  if n == 0 then
    __wlo_fail("IndexError", "pop from empty list", site)
  end
  local value = list[n]
  list[n] = nil
  list.n = n - 1
  return value
end

local function __wlo_list_contains(list, value, site)
  for i = 1, list.n do
    if __wlo_equal(list[i], value) then
      return true
    end
  end
  return false
end

-- For a value whose type is wider than the list's elements, which are
-- converted by `step` (see __wlo_convert) before comparing.
local function __wlo_list_contains_converted(list, value, step, site)
  for i = 1, list.n do
    if __wlo_equal(__wlo_convert(list[i], step), value) then
      return true
    end
  end
  return false
end

local function __wlo_dict_index(dict, key, site)
  if not dict.positions[key] then
    __wlo_fail("KeyError", "key not found", site)
  end
  return dict.values[key]
end

-- The default stands in only for a missing key; a stored None is a value.
local function __wlo_dict_get(dict, key, default, site)
  if dict.positions[key] then
    return dict.values[key]
  end
  return default
end

local function __wlo_dict_pop(dict, key, site)
  local position = dict.positions[key]
  if not position then
    __wlo_fail("KeyError", "key not found", site)
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

local function __wlo_tuple_items(tuple, site)
  local i = 0
  return function()
    if i < tuple.__wlo_tuple then
      i = i + 1
      return true, tuple[i]
    end
  end
end

local function __wlo_dict_items(dict, site)
  local i, version = 0, dict.version
  return function()
    if dict.version ~= version then
      __wlo_fail("RuntimeError", "dictionary changed size during iteration", site)
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

local function __wlo_bytes_items(data, site)
  local octets, i = data.__wlo_octets, 0
  return function()
    i = i + 1
    if i <= #octets then
      return true, octets:byte(i)
    end
  end
end

-- A built-in iterator advances one of the step functions above and stays
-- exhausted once it ends.
local function __wlo_iterator(step)
  return { "<iterator>", step = step }
end

local function __wlo_iterator_iter(iterator, site)
  return iterator
end

local function __wlo_iterator_next(iterator, site)
  if iterator.step then
    local more, value = iterator.step()
    if more then
      return value
    end
    iterator.step = nil
  end
  __wlo_fail("StopIteration", "", site)
end

local function __wlo_list_iter(list, site)
  return __wlo_iterator(__wlo_list_items(list, site))
end

local function __wlo_dict_iter(dict, site)
  return __wlo_iterator(__wlo_dict_items(dict, site))
end

local function __wlo_str_iter(text, site)
  return __wlo_iterator(__wlo_str_items(text, site))
end

local function __wlo_bytes_iter(data, site)
  return __wlo_iterator(__wlo_bytes_items(data, site))
end

-- The tuple holds its items in the item type's representation.
local function __wlo_tuple_iter(tuple, site)
  return __wlo_iterator(__wlo_tuple_items(tuple, site))
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
    __wlo_fail("ValueError", "empty separator", site)
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

local function __wlo_str_join_slice(sep, list, start, stop, site)
  start, stop = __wlo_slice_bounds(start, stop, list.n)
  return table.concat(list, sep, start + 1, stop)
end

-- The byte position of code point `k`, counting from 0, or one past the end.
local function __wlo_offset(text, k)
  local count = 0
  for pos in text:gmatch("()[^\128-\191]") do
    if count == k then
      return pos
    end
    count = count + 1
  end
  return #text + 1
end

-- Code points `first` up to but excluding `last` of a string of `n` code
-- points. ASCII text has one byte per code point.
local function __wlo_str_sub(text, n, first, last)
  if n == #text then
    return text:sub(first + 1, last)
  end
  return text:sub(__wlo_offset(text, first), __wlo_offset(text, last) - 1)
end

local function __wlo_str_index(text, i, site)
  local n = __wlo_code_points(text)
  local j = __wlo_normalize_index(i, n)
  if not j then
    __wlo_fail("IndexError", "string index out of range", site)
  end
  return __wlo_str_sub(text, n, j, j + 1)
end

local function __wlo_str_slice(text, start, stop, site)
  local n = __wlo_code_points(text)
  start, stop = __wlo_slice_bounds(start, stop, n)
  if stop <= start then
    return ""
  end
  return __wlo_str_sub(text, n, start, stop)
end

-- Pads `text` with spaces to `width` code points. A nil `align` is left for a
-- string `value` and right otherwise; `^` puts an odd space on the right.
local function __wlo_pad(text, width, align, value)
  local pad = width - __wlo_code_points(text)
  if pad <= 0 then
    return text
  end
  align = align or (type(value) == "string" and "<" or ">")
  if align == "<" then
    return text .. (" "):rep(pad)
  elseif align == ">" then
    return (" "):rep(pad) .. text
  end
  local left = math.floor(pad / 2)
  return (" "):rep(left) .. text .. (" "):rep(pad - left)
end

local function __wlo_str_ljust(text, width, site)
  return __wlo_pad(text, width, "<")
end

local function __wlo_str_rjust(text, width, site)
  return __wlo_pad(text, width, ">")
end

-- The C library converts exactly, rounding ties to even, at any precision;
-- string.format rejects precisions above 99.
local function __wlo_format_fixed(x, precision)
  if x ~= x then
    return "nan"
  elseif x == math.huge then
    return "inf"
  elseif x == -math.huge then
    return "-inf"
  end
  local size = 330 + precision
  local buffer = __wlo_ffi.new("char[?]", size)
  local length = __wlo_ffi.C.snprintf(buffer, size, "%.*f", __wlo_ffi.new("int", precision), x)
  return __wlo_ffi.string(buffer, length)
end

local function __wlo_ord(text, site)
  if __wlo_code_points(text) ~= 1 then
    __wlo_fail("ValueError", "expected one character", site)
  end
  return __wlo_code_point(text)
end

-- Surrogates are U+D800 through U+DFFF, and U+10FFFF is the last code point.
local function __wlo_chr(n, site)
  if n < 0 or n > 1114111 or (n >= 55296 and n <= 57343) then
    __wlo_fail("ValueError", "invalid code point", site)
  end
  if n < 128 then
    return string.char(n)
  elseif n < 2048 then
    return string.char(192 + math.floor(n / 64), 128 + n % 64)
  elseif n < 65536 then
    return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64)
  end
  return string.char(240 + math.floor(n / 262144), 128 + math.floor(n / 4096) % 64, 128 + math.floor(n / 64) % 64, 128 + n % 64)
end

-- A range's step is checked once, before a `for` over the range runs its
-- numbers directly rather than through an iterator.
local function __wlo_range_step(step, site)
  if step == 0 then
    __wlo_fail("ValueError", "range step must not be zero", site)
  end
end

local function __wlo_range(start, stop, step, site)
  __wlo_range_step(step, site)
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

-- A range value; each `iter` starts a fresh traversal.
local function __wlo_range_value(start, stop, step, site)
  if step == 0 then
    __wlo_fail("ValueError", "range step must not be zero", site)
  end
  return { "range", start = start, stop = stop, step = step }
end

local function __wlo_range_iter(range, site)
  return __wlo_iterator(__wlo_range(range.start, range.stop, range.step, site))
end

-- The name protocol dispatch finds a value's converters by: its class or
-- native type, or its built-in kind.
local function __wlo_tag(value)
  if type(value) == "string" then
    return "str"
  end
  return value.__wlo_class or value.__wlo_tuple and "tuple"
    or value.__wlo_octets and "bytes" or value.n and "list" or value[1] or "dict"
end

-- A generator runs `body` in a coroutine, from the first `next`. Its state is
-- "unstarted", "suspended", "running", or "done". Errors are caught inside the
-- coroutine, so their frames are recorded where they happen.
local function __wlo_generator(body)
  local co = coroutine.create(function()
    return xpcall(body, __wlo_catch)
  end)
  return { "<generator>", state = "unstarted", co = co }
end

local function __wlo_yield(value)
  if coroutine.yield(value) == __wlo_cancel then
    error(__wlo_cancel, 0)
  end
end

-- Raises `err` from a finished generator in its caller, whose frames follow
-- the generator's.
local function __wlo_generator_raise(err)
  if type(err) == "table" and err.__wlo_frames then
    for _, frame in ipairs(__wlo_frames()) do
      err.__wlo_frames[#err.__wlo_frames + 1] = frame
    end
  end
  error(err, 0)
end

local function __wlo_generator_next(generator, site)
  if generator.state == "running" then
    __wlo_fail("RuntimeError", "generator already running", site)
  elseif generator.state == "done" then
    __wlo_fail("StopIteration", "", site)
  end
  generator.state = "running"
  local _, value, err = coroutine.resume(generator.co)
  if coroutine.status(generator.co) == "suspended" then
    generator.state = "suspended"
    return value
  end
  generator.state = "done"
  if value then
    __wlo_fail("StopIteration", "", site)
  elseif type(err) == "table" and err.__wlo_class == "StopIteration" then
    __wlo_fail("RuntimeError", "generator raised StopIteration", site)
  end
  __wlo_generator_raise(err)
end

-- Closing runs a suspended body's pending cleanup; an unstarted body never
-- runs.
local function __wlo_generator_close(generator, site)
  if generator.state == "running" then
    __wlo_fail("RuntimeError", "generator already running", site)
  end
  if generator.state ~= "suspended" then
    generator.state = "done"
    return
  end
  generator.state = "running"
  local _, ok, err = coroutine.resume(generator.co, __wlo_cancel)
  generator.state = "done"
  if not ok and err ~= __wlo_cancel then
    __wlo_generator_raise(err)
  end
end

local function __wlo_generator_iter(generator, site)
  return generator
end

local function __wlo_generator_enter(generator, site)
  return generator
end

local function __wlo_generator_exit(generator, exception, site)
  __wlo_generator_close(generator, site)
end

-- A coroutine holds an async function's body until it is consumed, by an
-- await or by starting a task. Its body runs in the consuming task's Lua
-- coroutine, so a suspension inside it suspends the whole task.
local function __wlo_coroutine(body)
  return { "<coroutine>", body = body }
end

-- Returns the body of coroutine `c` and marks `c` consumed.
local function __wlo_consume(c, site)
  local body = c.body
  if not body then
    __wlo_fail("RuntimeError", "coroutine was already awaited or started", site)
  end
  c.body = nil
  return body
end

-- Runs coroutine `c` inline, returning its result or raising its exception.
local function __wlo_await(c, site)
  return __wlo_consume(c, site)()
end

local function __wlo_where(location)
  return __wlo_paths[location[3]] .. ":" .. location[1] .. ":" .. location[2]
end

-- Formats an uncaught failure with its recorded frames, innermost first.
-- LuaJIT skips the message handler for memory errors, so `err` may be a raw
-- string with no Willow frame left to locate it.
local function __wlo_report(err)
  if type(err) ~= "table" then
    err = __wlo_catch(err)
  end
  local class = err.__wlo_class and err.__wlo_class .. ": " or ""
  local where = err.__wlo_location and __wlo_where(err.__wlo_location) .. ": " or ""
  local lines = { where .. "error: " .. class .. err.message }
  local frames = err.__wlo_frames
  for i, frame in ipairs(frames) do
    if i > __wlo_MAX_FRAMES then
      lines[#lines + 1] = "  ... " .. (#frames - __wlo_MAX_FRAMES) .. " more frames"
      break
    end
    lines[#lines + 1] = (i == 1 and "  in " or "  called from ") .. frame[4] .. " at " .. __wlo_where(frame)
  end
  if frames.task then
    lines[#lines + 1] = "  in task started at " .. __wlo_where(frames.task)
  end
  return table.concat(lines, "\n")
end

-- A new list of the program arguments. They are validated here, on each call,
-- so a malformed argument raises where the program asks for it.
local function __wlo_args(site)
  local args = {}
  for i = 1, __wlo_argv.n do
    args[i] = __wlo_check_text(__wlo_argv[i], site)
  end
  return __wlo_list(args, __wlo_argv.n)
end

local function __wlo_run(main, ...)
  -- A write to a closed pipe then fails with EPIPE instead of ending the process.
  __wlo_ffi.C.__wlo_c_signal(13, __wlo_ffi.cast("void *", 1))
  __wlo_argv = { n = select("#", ...), ... }
  local ok, err = xpcall(main, __wlo_catch)
  if not ok then
    -- The status is already 1, so a failure to flush stdout adds nothing.
    io.stdout:flush()
    io.stderr:write(__wlo_report(err), "\n")
    os.exit(1)
  end
  __wlo_flush_streams()
end
