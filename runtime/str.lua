-- String helpers beyond the core ones, inlined after runtime/core.lua into
-- programs that use them. The helpers are the functions declared without
-- `local`. Whitespace and character classes are ASCII; see the spec.

local WHITESPACE = { [9] = true, [10] = true, [11] = true, [12] = true, [13] = true, [32] = true }

function __wlo_str_split(text, sep, maxsplit, site)
  local items = __wlo_list({}, 0)
  if sep == nil then
    local n = #text
    local pos = 1
    while true do
      while pos <= n and WHITESPACE[text:byte(pos)] do
        pos = pos + 1
      end
      if pos > n then
        break
      end
      local stop = pos
      if maxsplit ~= 0 then
        while stop <= n and not WHITESPACE[text:byte(stop)] do
          stop = stop + 1
        end
      else
        stop = n + 1
      end
      __wlo_list_append(items, text:sub(pos, stop - 1))
      maxsplit = maxsplit - 1
      pos = stop
    end
    return items
  end
  if sep == "" then
    __wlo_fail("ValueError", "empty separator", site)
  end
  local start = 1
  while maxsplit ~= 0 do
    local i, j = text:find(sep, start, true)
    if not i then
      break
    end
    __wlo_list_append(items, text:sub(start, i - 1))
    start = j + 1
    maxsplit = maxsplit - 1
  end
  __wlo_list_append(items, text:sub(start))
  return items
end

-- Separators are matched from the right, so overlapping ones split as in
-- Python: "aaa".rsplit("aa") is ["a", ""].
function __wlo_str_rsplit(text, sep, maxsplit, site)
  local pieces, n = {}, 0
  local stop = #text
  if sep == nil then
    while true do
      while stop > 0 and WHITESPACE[text:byte(stop)] do
        stop = stop - 1
      end
      if stop == 0 then
        break
      end
      local start = 1
      if maxsplit ~= 0 then
        start = stop
        while start > 1 and not WHITESPACE[text:byte(start - 1)] do
          start = start - 1
        end
      end
      n = n + 1
      pieces[n] = text:sub(start, stop)
      maxsplit = maxsplit - 1
      stop = start - 1
    end
  else
    if sep == "" then
      __wlo_fail("ValueError", "empty separator", site)
    end
    local width = #sep
    local i = stop - width + 1
    while maxsplit ~= 0 and i >= 1 do
      if text:sub(i, i + width - 1) == sep then
        n = n + 1
        pieces[n] = text:sub(i + width, stop)
        maxsplit = maxsplit - 1
        stop = i - 1
        i = i - width
      else
        i = i - 1
      end
    end
    n = n + 1
    pieces[n] = text:sub(1, stop)
  end
  local items = {}
  for k = 1, n do
    items[k] = pieces[n + 1 - k]
  end
  return __wlo_list(items, n)
end

function __wlo_str_splitlines(text, keepends, site)
  local items = __wlo_list({}, 0)
  local pos = 1
  while pos <= #text do
    local i = text:find("[\r\n]", pos)
    if not i then
      __wlo_list_append(items, text:sub(pos))
      break
    end
    local stop = i
    if text:byte(i) == 13 and text:byte(i + 1) == 10 then
      stop = i + 1
    end
    __wlo_list_append(items, text:sub(pos, keepends and stop or i - 1))
    pos = stop + 1
  end
  return items
end

function __wlo_str_lstrip(text, site)
  return (text:gsub("^[ \t\n\v\f\r]+", ""))
end

function __wlo_str_rstrip(text, site)
  local stop = #text
  while stop > 0 and WHITESPACE[text:byte(stop)] do
    stop = stop - 1
  end
  return text:sub(1, stop)
end

function __wlo_str_removeprefix(text, prefix, site)
  if text:sub(1, #prefix) == prefix then
    return text:sub(#prefix + 1)
  end
  return text
end

function __wlo_str_removesuffix(text, suffix, site)
  if suffix ~= "" and text:sub(-#suffix) == suffix then
    return text:sub(1, #text - #suffix)
  end
  return text
end

function __wlo_str_isascii(text, site)
  return not text:find("[\128-\255]")
end

function __wlo_str_isspace(text, site)
  return text:find("^[ \t\n\v\f\r]+$") ~= nil
end

function __wlo_str_isdigit(text, site)
  return text:find("^[0-9]+$") ~= nil
end

function __wlo_str_isalpha(text, site)
  return text:find("^[A-Za-z]+$") ~= nil
end

function __wlo_str_isalnum(text, site)
  return text:find("^[A-Za-z0-9]+$") ~= nil
end
