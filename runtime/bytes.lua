-- Bytes helpers, inlined after runtime/core.lua into programs that use them.
-- A bytes value is { __wlo_octets = <Lua string> }. The helpers are the
-- functions declared without `local`.

local function __wlo_new_bytes(octets)
  return { __wlo_octets = octets }
end

function __wlo_bytes(values, site)
  local chars = {}
  for i = 1, values.n do
    local value = values[i]
    if value < 0 or value > 255 then
      __wlo_fail("ValueError", "bytes must be in range(0, 256)", site)
    end
    chars[i] = string.char(value)
  end
  return __wlo_new_bytes(table.concat(chars))
end

function __wlo_bytes_concat(a, b, site)
  return __wlo_new_bytes(a.__wlo_octets .. b.__wlo_octets)
end

function __wlo_bytes_index(data, i, site)
  local j = __wlo_normalize_index(i, #data.__wlo_octets)
  if not j then
    __wlo_fail("IndexError", "index out of range", site)
  end
  return data.__wlo_octets:byte(j + 1)
end

function __wlo_bytes_slice(data, start, stop, site)
  start, stop = __wlo_slice_bounds(start, stop, #data.__wlo_octets)
  return __wlo_new_bytes(data.__wlo_octets:sub(start + 1, stop))
end

function __wlo_str_encode(text, site)
  return __wlo_new_bytes(text)
end

function __wlo_bytes_decode(data, site)
  return __wlo_check_text(data.__wlo_octets, site)
end
