local function count_primes(limit)
  local flags, count = {}, 0
  for i = 0, limit - 1 do flags[i] = true end
  for i = 2, limit - 1 do
    if flags[i] then
      count = count + 1
      for j = i + i, limit - 1, i do flags[j] = false end
    end
  end
  return count
end
local n = tonumber(arg[1])
for i = 0, 2 do
  local limit = 10000 * 2 ^ (n - i)
  io.write(string.format("Primes up to %8d %8d\n", limit, count_primes(limit)))
end
