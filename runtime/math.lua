-- Math helpers, inlined after runtime/core.lua into programs that use them.
-- The helpers are the functions declared without `local`. Transcendental
-- functions return what the host libm does: NaN for a domain error and
-- infinity for overflow.

local __wlo_math_floor_lua, __wlo_math_ceil_lua = math.floor, math.ceil
local __wlo_math_pow_lua, __wlo_math_exp_lua = math.pow, math.exp
local __wlo_math_log_lua, __wlo_math_log10_lua = math.log, math.log10
local __wlo_math_sin_lua, __wlo_math_cos_lua, __wlo_math_tan_lua = math.sin, math.cos, math.tan
local __wlo_math_asin_lua, __wlo_math_acos_lua = math.asin, math.acos
local __wlo_math_atan_lua, __wlo_math_atan2_lua = math.atan, math.atan2

-- Converts a rounded float to an int, which has no negative zero.
local function __wlo_math_to_int(value, site)
  if value ~= value or value > __wlo_MAX_INT or value < -__wlo_MAX_INT then
    __wlo_fail("ValueError", "cannot convert float to int", site)
  end
  if value == 0 then
    return 0
  end
  return value
end

function __wlo_math_floor(x, site)
  return __wlo_math_to_int(__wlo_math_floor_lua(x), site)
end

function __wlo_math_ceil(x, site)
  return __wlo_math_to_int(__wlo_math_ceil_lua(x), site)
end

function __wlo_math_isfinite(x, site)
  return x == x and x ~= 1 / 0 and x ~= -1 / 0
end

function __wlo_math_isnan(x, site)
  return x ~= x
end

function __wlo_math_isinf(x, site)
  return x == 1 / 0 or x == -1 / 0
end

function __wlo_math_pow(x, y, site)
  return __wlo_math_pow_lua(x, y)
end

function __wlo_math_exp(x, site)
  return __wlo_math_exp_lua(x)
end

function __wlo_math_log(x, site)
  return __wlo_math_log_lua(x)
end

function __wlo_math_log10(x, site)
  return __wlo_math_log10_lua(x)
end

function __wlo_math_sin(x, site)
  return __wlo_math_sin_lua(x)
end

function __wlo_math_cos(x, site)
  return __wlo_math_cos_lua(x)
end

function __wlo_math_tan(x, site)
  return __wlo_math_tan_lua(x)
end

function __wlo_math_asin(x, site)
  return __wlo_math_asin_lua(x)
end

function __wlo_math_acos(x, site)
  return __wlo_math_acos_lua(x)
end

function __wlo_math_atan(x, site)
  return __wlo_math_atan_lua(x)
end

function __wlo_math_atan2(y, x, site)
  return __wlo_math_atan2_lua(y, x)
end
