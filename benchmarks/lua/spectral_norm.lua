local function a(i, j)
  local ij = i + j
  return 1.0 / (ij * (ij + 1) / 2 + i + 1)
end
local function times(n, v, out)
  for i = 0, n - 1 do
    local t = 0
    for j = 0, n - 1 do t = t + a(i, j) * v[j] end
    out[i] = t
  end
end
local function times_t(n, v, out)
  for i = 0, n - 1 do
    local t = 0
    for j = 0, n - 1 do t = t + a(j, i) * v[j] end
    out[i] = t
  end
end
local n = tonumber(arg[1])
local u, v, s = {}, {}, {}
for i = 0, n - 1 do u[i], v[i], s[i] = 1, 0, 0 end
for _ = 1, 10 do times(n, u, s); times_t(n, s, v); times(n, v, s); times_t(n, s, u) end
local vbv, vv = 0, 0
for i = 0, n - 1 do vbv = vbv + u[i] * v[i]; vv = vv + v[i] * v[i] end
io.write(string.format("%.9f\n", math.sqrt(vbv / vv)))
