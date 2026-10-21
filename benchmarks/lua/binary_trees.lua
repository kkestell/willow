local function make(d)
  if d == 0 then return { left = false } end
  return { left = make(d - 1), right = make(d - 1) }
end
local function check(t)
  if not t.left then return 1 end
  return 1 + check(t.left) + check(t.right)
end
local n = tonumber(arg[1])
local min_depth = 4
local max_depth = math.max(min_depth + 2, n)
io.write("stretch tree of depth ", max_depth + 1, "\t check: ", check(make(max_depth + 1)), "\n")
local long_lived = make(max_depth)
for d = min_depth, max_depth, 2 do
  local iterations = 2 ^ (max_depth - d + min_depth)
  local total = 0
  for _ = 1, iterations do total = total + check(make(d)) end
  io.write(iterations, "\t trees of depth ", d, "\t check: ", total, "\n")
end
io.write("long lived tree of depth ", max_depth, "\t check: ", check(long_lived), "\n")
