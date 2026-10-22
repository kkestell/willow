-- Built-in numeric and collection helpers, inlined after runtime/core.lua into
-- programs that use them. An iterable argument arrives as a `for` step
-- function, which returns true and the next item, or nothing at the end. The
-- helpers are the functions declared without `local`.

function __wlo_abs(x, site)
  return math.abs(x)
end

-- Rounds half to even; the nearest-integer result must be an `int`.
function __wlo_round(x, site)
  if x ~= x or x == math.huge or x == -math.huge then
    __wlo_fail("ValueError", "cannot round float to int", site)
  end
  local result = __wlo_floor(x)
  local fraction = x - result
  if fraction > 0.5 or fraction == 0.5 and result % 2 == 1 then
    result = result + 1
  end
  if result > __wlo_MAX_INT or result < -__wlo_MAX_INT then
    __wlo_fail("ValueError", "cannot round float to int", site)
  end
  -- Rounding -0.4 gives -0.0, and there is no integer negative zero.
  return result == 0 and 0 or result
end

-- Whether `a` is ahead of `b` for `op`, "<" for min and ">" for max.
local function __wlo_ahead(a, b, op)
  if __wlo_type(a) == "table" then
    return __wlo_tuple_order(a, b, op)
  elseif op == "<" then
    return a < b
  end
  return a > b
end

local function __wlo_check_comparable(value, site)
  if __wlo_has_nan(value) then
    __wlo_fail("ValueError", "cannot compare NaN", site)
  end
end

-- The first of `a` and `b` that no other is ahead of.
local function __wlo_extreme(a, b, op, site)
  __wlo_check_comparable(a, site)
  __wlo_check_comparable(b, site)
  if __wlo_ahead(b, a, op) then
    return b
  end
  return a
end

function __wlo_min2(a, b, site)
  return __wlo_extreme(a, b, "<", site)
end

function __wlo_max2(a, b, site)
  return __wlo_extreme(a, b, ">", site)
end

local function __wlo_extreme_items(step, op, name, site)
  local more, best = step()
  if not more then
    __wlo_fail("ValueError", name .. "() of an empty iterable", site)
  end
  __wlo_check_comparable(best, site)
  for _, item in step do
    __wlo_check_comparable(item, site)
    if __wlo_ahead(item, best, op) then
      best = item
    end
  end
  return best
end

function __wlo_min_items(step, site)
  return __wlo_extreme_items(step, "<", "min", site)
end

function __wlo_max_items(step, site)
  return __wlo_extreme_items(step, ">", "max", site)
end

function __wlo_sum(step, site)
  local total = 0
  for _, item in step do
    total = __wlo_add(total, item, site)
  end
  return total
end

-- The first item starts the total, so a sum of one -0.0 stays -0.0.
function __wlo_sum_float(step, site)
  local more, total = step()
  if not more then
    return 0
  end
  for _, item in step do
    total = total + item
  end
  return total
end

function __wlo_any(step, site)
  for _, item in step do
    if item then
      return true
    end
  end
  return false
end

function __wlo_all(step, site)
  for _, item in step do
    if not item then
      return false
    end
  end
  return true
end

-- The items of `step` in a new Lua array and their count.
local function __wlo_collect(step)
  local items, n = {}, 0
  for _, item in step do
    n = n + 1
    items[n] = item
  end
  return items, n
end

function __wlo_list_from(step, site)
  return __wlo_list(__wlo_collect(step))
end

-- The input is collected first, so extending a list by itself works and an
-- iteration failure leaves the list unchanged.
function __wlo_list_extend(list, step, site)
  local items, n = __wlo_collect(step)
  local base = list.n
  for i = 1, n do
    list[base + i] = items[i]
  end
  list.n = base + n
end

function __wlo_list_reverse(list, site)
  local n = list.n
  for i = 1, __wlo_floor(n / 2) do
    list[i], list[n + 1 - i] = list[n + 1 - i], list[i]
  end
end

function __wlo_enumerate(step, start, site)
  local index
  return __wlo_iterator(function()
    local more, item = step()
    if not more then
      return nil
    end
    index = index and __wlo_add(index, 1, site) or start
    return true, { __wlo_tuple = 2, index, item }
  end)
end

function __wlo_zip(first, second, site)
  return __wlo_iterator(function()
    local more, a = first()
    if not more then
      return nil
    end
    local more_b, b = second()
    if not more_b then
      return nil
    end
    return true, { __wlo_tuple = 2, a, b }
  end)
end

function __wlo_dict_keys(dict, site)
  return __wlo_iterator(__wlo_dict_items(dict, site))
end

-- A step over the entries of `dict` that returns `entry(key)` for each.
local function __wlo_dict_entries_step(dict, site, entry)
  local i, version = 0, dict.version
  return __wlo_iterator(function()
    if dict.version ~= version then
      __wlo_fail("RuntimeError", "dictionary changed size during iteration", site)
    end
    if i < #dict.keys then
      i = i + 1
      return true, entry(dict.keys[i])
    end
  end)
end

function __wlo_dict_values(dict, site)
  return __wlo_dict_entries_step(dict, site, function(key)
    return dict.values[key]
  end)
end

function __wlo_dict_entries(dict, site)
  return __wlo_dict_entries_step(dict, site, function(key)
    return { __wlo_tuple = 2, key, dict.values[key] }
  end)
end
