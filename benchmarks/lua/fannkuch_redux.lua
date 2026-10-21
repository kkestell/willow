local n = tonumber(arg[1])
local perm1, perm, count = {}, {}, {}
for i = 0, n - 1 do perm1[i], perm[i], count[i] = i, 0, 0 end
local max_flips, checksum, permutations, r = 0, 0, 0, n
while true do
  while r ~= 1 do count[r - 1] = r; r = r - 1 end
  for i = 0, n - 1 do perm[i] = perm1[i] end
  local flips, k = 0, perm[0]
  while k ~= 0 do
    local lo, hi = 0, k
    while lo < hi do perm[lo], perm[hi] = perm[hi], perm[lo]; lo = lo + 1; hi = hi - 1 end
    flips = flips + 1
    k = perm[0]
  end
  if flips > max_flips then max_flips = flips end
  if permutations % 2 == 0 then checksum = checksum + flips else checksum = checksum - flips end
  while true do
    if r == n then
      io.write(checksum, "\nPfannkuchen(", n, ") = ", max_flips, "\n")
      return
    end
    local first = perm1[0]
    for i = 0, r - 1 do perm1[i] = perm1[i + 1] end
    perm1[r] = first
    count[r] = count[r] - 1
    if count[r] > 0 then break end
    r = r + 1
  end
  permutations = permutations + 1
end
