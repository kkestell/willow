-- Prototype of §15 on LuaJIT coroutines, in the shape the emitter would produce.
-- Cancellation = one sentinel (the existing __wlo_cancel) + a `cancelled` flag on
-- groups + a per-task `scope` chain. Protection = task.scope = nil.
local ffi = require("ffi")
ffi.cdef [[ int poll(void *fds, unsigned long n, int timeout); ]]

local CANCEL = {}               -- same role as runtime/core.lua __wlo_cancel
local function catch(e) return e end
local function try(body)        -- __wlo_try, unchanged
  local ok, code, value = xpcall(body, catch)
  if ok then return code, value end
  if code == CANCEL then return "cancel", code end
  if type(code) ~= "table" or not code.class then error(code, 0) end
  return "raise", code
end

local current               -- running task
local ready, sleepers, suspended = {}, {}, {}   -- suspended: task -> true
local clock = 0              -- virtual time; poll() only to show the shape

-- First cancelled group reachable from the task's scope, or nil.
local function pending(task)
  local g = task.scope
  while g do
    if g.cancelled then return g end
    g = g.parent
  end
end

local function checkpoint()
  if pending(current) then error(CANCEL, 0) end
end

-- Suspend; `interruptible` waits are woken by delivery.
local function suspend(interruptible)
  local task = current
  task.interruptible = interruptible
  task.wait = (task.wait or 0) + 1
  suspended[task] = true
  local signal = coroutine.yield()
  suspended[task] = nil
  if signal == CANCEL then error(CANCEL, 0) end
  return signal
end

-- `id` names the wait being ended; a stale wake for an earlier wait is ignored.
local function wake(task, signal, id)
  if suspended[task] and not task.queued and (id == nil or id == task.wait) then
    task.queued = true
    ready[#ready + 1] = { task, signal }
  end
end

-- Scan suspended tasks; cancel is rare so O(n) is fine.
local function deliver()
  for task in pairs(suspended) do
    if task.interruptible and pending(task) then wake(task, CANCEL) end
  end
end

local function sleep(t)                 -- an async native op
  checkpoint()
  local task = current
  sleepers[#sleepers + 1] = { at = clock + t, task = task, id = (task.wait or 0) + 1 }
  suspend(true)
end

-- Coroutine objects: awaiting runs the body inline, in the current task.
local function coro(body) return { body = body, consumed = false } end
local function consume(c)
  if c.consumed then error({ class = "RuntimeError", message = "coroutine already consumed" }, 0) end
  c.consumed = true
  return c.body
end

local await_task
local function await(x)
  checkpoint()                          -- before consumption / before the op
  if x.body then return consume(x)() end
  return await_task(x)
end

-- Tasks
local function finish(task, ok, err, value)
  if ok then task.state, task.value = "done", value
  elseif err == CANCEL then task.state = "cancelled"
  else task.state, task.error = "failed", err end
  local g = task.group
  g.children[task], g.count = nil, g.count - 1
  if task.state == "failed" and not g.failure then
    g.failure, g.cancelled = err, true
    deliver()
  end
  for _, w in ipairs(task.waiters) do wake(w[1], nil, w[2]) end
  task.waiters = nil
  if g.count == 0 and g.joiner then wake(g.joiner) end
end

local function spawn(group, body, root)
  local task = { waiters = {}, scope = group, group = group, state = "running" }
  task.co = coroutine.create(function()
    local saved = task.scope
    local ok, err, value = xpcall(function() return nil, body() end, catch)
    task.scope = saved
    if not root then finish(task, ok, err, value) else task.ok, task.err = ok, err end
  end)
  ready[#ready + 1] = { task }
  task.queued = true
  return task
end

await_task = function(t)
  if t.state == "running" then
    t.waiters[#t.waiters + 1] = { current, (current.wait or 0) + 1 }
    suspend(true)                         -- stale waiter entries are harmless: wake() checks suspended
  end
  if t.state == "done" then return t.value end
  if t.state == "failed" then error(t.error, 0) end
  error({ class = "RuntimeError", message = "task was cancelled" }, 0)
end

-- Groups
local function group_new() return { state = "inactive", children = {}, count = 0 } end
local function group_enter(g)
  g.state, g.parent, current.scope = "active", current.scope, g
end
local function group_start(g, c)
  if g.state ~= "active" or g.failure or pending({ scope = g }) then
    error({ class = "RuntimeError", message = "group is not accepting tasks" }, 0)
  end
  local t = spawn(g, consume(c))
  g.children[t], g.count = true, g.count + 1
  return t
end
local function group_cancel(g)
  if g.state ~= "active" then error({ class = "RuntimeError", message = "inactive group" }, 0) end
  if not g.cancelled then g.cancelled = true; deliver() end
end
-- Runs where the Try's finally would; returns the new departure.
local function group_exit(g, code, value)
  current.scope = g.parent
  if code == "raise" and not g.failure then g.failure, g.cancelled = value, true; deliver() end
  while g.count > 0 do g.joiner = current; suspend(false) end   -- join: never abandoned
  g.state = "exited"
  if g.failure then return "raise", g.failure end
  if pending(current) then return "cancel", CANCEL end          -- outer request: not absorbable
  if code == "cancel" then return nil end                        -- absorb own stop
  return code, value
end

-- Protected finally, as the emitter would write it in async code.
local function try_finally(body, finally)
  local saved = current.scope
  local code, value = try(body)
  current.scope = nil                    -- protect
  finally()
  current.scope = saved                  -- unprotect (not a checkpoint)
  if code == "raise" or code == "cancel" then error(value, 0) end
  return code, value
end

-- Loop
local function run(main)
  local root = spawn(nil, main, true)
  root.scope = nil
  while true do
    while #ready > 0 do
      local batch = ready; ready = {}
      for _, item in ipairs(batch) do
        local task, signal = item[1], item[2]
        task.queued = false
        current = task
        assert(coroutine.resume(task.co, signal))
        current = nil
      end
    end
    if coroutine.status(root.co) == "dead" then return root end
    if #sleepers == 0 then error("deadlock: no runnable task and nothing to wait for") end
    -- Due timers wake together; a real loop would use a heap.
    local first = math.huge
    for _, s in ipairs(sleepers) do first = math.min(first, s.at) end
    ffi.C.poll(nil, 0, 0)
    clock = first
    local rest = {}
    for _, s in ipairs(sleepers) do
      if s.at <= clock then wake(s.task, nil, s.id) else rest[#rest + 1] = s end
    end
    sleepers = rest
  end
end

return { run = run, coro = coro, await = await, sleep = sleep, try = try, try_finally = try_finally,
  group_new = group_new, group_enter = group_enter, group_start = group_start, group_cancel = group_cancel,
  group_exit = group_exit, CANCEL = CANCEL, pending = pending, current = function() return current end,
  clock = function() return clock end, checkpoint = checkpoint }
