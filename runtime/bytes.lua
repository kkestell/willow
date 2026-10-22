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

function __wlo_bytes_find(data, sub, site)
  local i = data.__wlo_octets:find(sub.__wlo_octets, 1, true)
  return i and i - 1 or -1
end

function __wlo_bytes_startswith(data, prefix, site)
  local octets, head = data.__wlo_octets, prefix.__wlo_octets
  return octets:sub(1, #head) == head
end

function __wlo_bytes_endswith(data, suffix, site)
  local octets, tail = data.__wlo_octets, suffix.__wlo_octets
  return tail == "" or octets:sub(-#tail) == tail
end

function __wlo_bytes_split(data, sep, maxsplit, site)
  local octets, separator = data.__wlo_octets, sep.__wlo_octets
  if separator == "" then
    __wlo_fail("ValueError", "empty separator", site)
  end
  local items = __wlo_list({}, 0)
  local start, count = 1, 0
  while maxsplit < 0 or count < maxsplit do
    local i, j = octets:find(separator, start, true)
    if not i then
      break
    end
    __wlo_list_append(items, __wlo_new_bytes(octets:sub(start, i - 1)))
    start, count = j + 1, count + 1
  end
  __wlo_list_append(items, __wlo_new_bytes(octets:sub(start)))
  return items
end

function __wlo_bytes_hex(data, site)
  return (data.__wlo_octets:gsub(".", function(octet)
    return string.format("%02x", octet:byte())
  end))
end

-- Pairs of hex digits, with ASCII whitespace allowed between pairs.
function __wlo_bytes_fromhex(text, site)
  local chars, n, i = {}, 0, 1
  while true do
    i = text:find("[^ \t\n\v\f\r]", i)
    if not i then
      return __wlo_new_bytes(table.concat(chars))
    end
    local pair = text:match("^%x%x", i)
    if not pair then
      __wlo_fail("ValueError", "invalid hex string", site)
    end
    n = n + 1
    chars[n] = string.char(tonumber(pair, 16))
    i = i + 2
  end
end
