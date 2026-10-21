io.stdout:setvbuf("no")
package.path = "./?.lua;" .. package.path
local A = require("proto")
local function now() return os.clock() end
local N = 1e6
local function leaf(x) return x + 1 end
local t0 = now(); local s = 0
for i = 1, N do s = leaf(s) end
local plain = now() - t0

-- inline await: allocate coroutine object + closure, checkpoint walk (depth 3), call
local root = { scope = { parent = { parent = { } } } }
local function cur() return root end
local function pending(task) local g = task.scope while g do if g.cancelled then return g end g = g.parent end end
local function mk(x) return { consumed = false, body = function() return x + 1 end } end
local function await(c) if pending(root) then error("c") end; if c.consumed then error("x") end; c.consumed = true; return c.body() end
t0 = now(); s = 0
for i = 1, N do s = await(mk(s)) end
local inline = now() - t0
print(string.format("plain call %.1f ns/op; inline await (alloc+walk+call) %.1f ns/op", plain / N * 1e9, inline / N * 1e9))

-- try/finally with scope save/restore vs without
local function try(body) local ok, a, b = xpcall(body, debug.traceback) return a, b end
t0 = now()
for i = 1, N do local c, v = try(function() return "return", i end) end
local t1 = now() - t0
t0 = now()
for i = 1, N do local saved = root.scope; local c, v = try(function() return "return", i end); root.scope = nil; root.scope = saved end
local t2 = now() - t0
print(string.format("try %.1f ns; try+protect save/restore %.1f ns", t1 / N * 1e9, t2 / N * 1e9))

-- coroutine switch cost: resume/yield ping-pong
local co = coroutine.wrap(function() while true do coroutine.yield() end end)
t0 = now(); for i = 1, N do co() end
print(string.format("resume+yield %.1f ns", (now() - t0) / N * 1e9))

-- yield from inside nested xpcall frames (try blocks) within a task
local co2 = coroutine.wrap(function() while true do try(function() try(function() coroutine.yield() end) end) end end)
t0 = now(); for i = 1, N do co2() end
print(string.format("resume+yield through 2 xpcall frames %.1f ns", (now() - t0) / N * 1e9))

-- memory per suspended task (coroutine + closure + task table)
collectgarbage(); collectgarbage()
local before = collectgarbage("count")
local tasks = {}
local M = 100000
for i = 1, M do
  local task = { waiters = {}, scope = root.scope }
  task.co = coroutine.create(function() local a, b = 1, 2; coroutine.yield(); return a + b end)
  coroutine.resume(task.co)
  tasks[i] = task
end
collectgarbage(); collectgarbage()
print(string.format("suspended task memory: %.2f KB each", (collectgarbage("count") - before) / M))

-- full scheduler: 100k tasks each sleeping once inside a group
t0 = now()
A.run(function()
  local g = A.group_new()
  A.group_enter(g)
  local code, v = A.try(function()
    for i = 1, 100000 do A.group_start(g, A.coro(function() A.sleep(1) end)) end
  end)
  A.group_exit(g, code, v)
end)
print(string.format("100k start+sleep+join via prototype scheduler: %.2f s", now() - t0))
