local N = 200000
local sentinel = {}
local function thrower() error(sentinel, 0) end
local t0 = os.clock()
for i = 1, N do pcall(thrower) end
print(string.format("pcall+error: %.2f us/op", (os.clock() - t0) / N * 1e6))
t0 = os.clock()
for i = 1, N do
  local co = coroutine.create(function() coroutine.yield() error(sentinel, 0) end)
  coroutine.resume(co); coroutine.resume(co)
end
print(string.format("coroutine create+yield+error: %.2f us/op", (os.clock() - t0) / N * 1e6))
