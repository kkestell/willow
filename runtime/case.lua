-- Unicode case conversion, inlined after runtime/case_data.lua into programs
-- that call lower or upper.

-- Expands simple-mapping runs into a code point map on first use.
local function __wlo_case_map(runs)
  local map = {}
  for i = 1, #runs, 4 do
    for code = runs[i], runs[i + 1], runs[i + 2] do
      map[code] = code + runs[i + 3]
    end
  end
  return map
end

local __wlo_lower_map, __wlo_upper_map

local function __wlo_in_ranges(ranges, code)
  local low, high = 1, #ranges / 2
  while low <= high do
    local mid = math.floor((low + high) / 2)
    if code < ranges[2 * mid - 1] then
      high = mid - 1
    elseif code > ranges[2 * mid] then
      low = mid + 1
    else
      return true
    end
  end
  return false
end

local function __wlo_decode(text)
  local codes = {}
  for char in text:gmatch(__wlo_CODE_POINT) do
    local value = char:byte(1)
    if #char > 1 then
      value = value % 2 ^ (7 - #char)
      for i = 2, #char do
        value = value * 64 + char:byte(i) % 64
      end
    end
    codes[#codes + 1] = value
  end
  return codes
end

-- Final_Sigma: a cased code point precedes `i` and none follows it, skipping
-- case-ignorable code points in both directions.
local function __wlo_final_sigma(codes, i)
  local function cased_beside(from, step)
    local j = from + step
    while codes[j] and __wlo_in_ranges(__wlo_CASE_IGNORABLE, codes[j]) do
      j = j + step
    end
    return codes[j] ~= nil and __wlo_in_ranges(__wlo_CASED, codes[j])
  end
  return cased_beside(i, -1) and not cased_beside(i, 1)
end

local function __wlo_convert_case(text, full, map, lower)
  local codes = __wlo_decode(text)
  local parts = {}
  for i, code in ipairs(codes) do
    if lower and code == 0x3A3 then
      parts[i] = __wlo_final_sigma(codes, i) and "\207\130" or "\207\131"
    else
      parts[i] = full[code] or __wlo_chr(map[code] or code)
    end
  end
  return table.concat(parts)
end

local function __wlo_str_lower(text, site)
  if not text:find("[\128-\255]") then
    return text:lower()
  end
  __wlo_lower_map = __wlo_lower_map or __wlo_case_map(__wlo_LOWER_RUNS)
  return __wlo_convert_case(text, __wlo_LOWER_FULL, __wlo_lower_map, true)
end

local function __wlo_str_upper(text, site)
  if not text:find("[\128-\255]") then
    return text:upper()
  end
  __wlo_upper_map = __wlo_upper_map or __wlo_case_map(__wlo_UPPER_RUNS)
  return __wlo_convert_case(text, __wlo_UPPER_FULL, __wlo_upper_map, false)
end
