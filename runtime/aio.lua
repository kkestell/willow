-- The async event loop and task groups, inlined after runtime/core.lua into
-- programs that call its helpers, which are the functions declared without
-- `local`. A task is a Lua coroutine; it suspends by yielding to the loop,
-- which resumes ready tasks in the order they became ready and waits on
-- timers and descriptors with poll.
--
-- Cancellation is core's __wlo_cancel raised at a checkpoint. A group's stop
-- or failure sets its `cancelled` flag, which stays set until the group exits.
-- A task's `scope` is the innermost group whose requests reach it; the chain
-- of `parent` groups gives the outer ones. A protected `finally` or resource
-- exit runs with the scope set to nil.

__wlo_ffi.cdef([[
typedef struct { int fd; short events; short revents; } __wlo_aio_pollfd_t;
int __wlo_c_aio_poll(__wlo_aio_pollfd_t *fds, unsigned long count, int timeout) __asm__("poll");
]])

local __wlo_aio_EINTR = 4

local __wlo_aio_current -- the running task
local __wlo_aio_ready -- tasks to resume, in the order they became ready
local __wlo_aio_timers -- a min-heap of { at, task, wait } by time, then wait id
local __wlo_aio_fd_waits -- { fd, events, task, wait } entries
local __wlo_aio_waiting -- the set of suspended tasks
local __wlo_aio_last_wait = 0

local function __wlo_aio_now()
  return __wlo_clock(__wlo_CLOCK_MONOTONIC)
end

-- Starts a wait for the current task and returns the task and the wait's id.
-- Ids increase across all tasks, so an id also orders timers set at the same
-- time. A task's `wait` is nil while it runs or is queued, so a waker for a
-- finished wait is ignored. Delivering a request ends an `interruptible` wait.
local function __wlo_aio_wait(interruptible)
  local task = __wlo_aio_current
  __wlo_aio_last_wait = __wlo_aio_last_wait + 1
  task.wait, task.interruptible = __wlo_aio_last_wait, interruptible
  __wlo_aio_waiting[task] = true
  return task, __wlo_aio_last_wait
end

-- Queues `task` to resume with `signal` if it is still in wait `id`.
local function __wlo_aio_wake(task, id, signal)
  if task.wait == id then
    task.wait, task.signal = nil, signal
    __wlo_aio_waiting[task] = nil
    __wlo_aio_ready[#__wlo_aio_ready + 1] = task
  end
end

-- Whether a request from one of `task`'s groups is in effect.
local function __wlo_aio_pending(task)
  local group = task.scope
  while group do
    if group.cancelled then
      return true
    end
    group = group.parent
  end
  return false
end

local function __wlo_aio_checkpoint()
  if __wlo_aio_pending(__wlo_aio_current) then
    error(__wlo_cancel, 0)
  end
end

-- Requests a stop of `group` and wakes the interruptible waits it reaches, in
-- the order they began, so cleanup runs in a repeatable order.
local function __wlo_aio_request(group)
  if group.cancelled then
    return
  end
  group.cancelled = true
  local woken = {}
  for task in pairs(__wlo_aio_waiting) do
    if task.interruptible and __wlo_aio_pending(task) then
      woken[#woken + 1] = task
    end
  end
  table.sort(woken, function(a, b)
    return a.wait < b.wait
  end)
  for _, task in ipairs(woken) do
    __wlo_aio_wake(task, task.wait)
  end
end


local function __wlo_aio_before(a, b)
  return a.at < b.at or a.at == b.at and a.wait < b.wait
end

local function __wlo_aio_push_timer(timer)
  local heap = __wlo_aio_timers
  local i = #heap + 1
  heap[i] = timer
  while i > 1 do
    local parent = math.floor(i / 2)
    if not __wlo_aio_before(heap[i], heap[parent]) then
      break
    end
    heap[i], heap[parent] = heap[parent], heap[i]
    i = parent
  end
end

local function __wlo_aio_pop_timer()
  local heap = __wlo_aio_timers
  local top, n = heap[1], #heap
  local last = heap[n]
  heap[n] = nil
  n = n - 1
  if n > 0 then
    heap[1] = last
    local i = 1
    while true do
      local child = 2 * i
      if child > n then
        break
      elseif child < n and __wlo_aio_before(heap[child + 1], heap[child]) then
        child = child + 1
      end
      if not __wlo_aio_before(heap[child], heap[i]) then
        break
      end
      heap[i], heap[child] = heap[child], heap[i]
      i = child
    end
  end
  return top
end

-- Waits until a descriptor is ready or the first timer is due, without
-- waiting when a task is ready, and queues the tasks those events end.
local function __wlo_aio_poll()
  local timers = __wlo_aio_timers
  -- Dropping only stale timers from the top suffices: the heap empties only
  -- when no live timer remains.
  while timers[1] and timers[1].task.wait ~= timers[1].wait do
    __wlo_aio_pop_timer()
  end
  local waits = {}
  for _, entry in ipairs(__wlo_aio_fd_waits) do
    if entry.task.wait == entry.wait then
      waits[#waits + 1] = entry
    end
  end
  __wlo_aio_fd_waits = waits
  if not __wlo_aio_ready[1] and not timers[1] and not waits[1] then
    error({ message = "deadlock: all tasks are waiting", __wlo_frames = {} }, 0)
  end

  local timeout = -1
  if __wlo_aio_ready[1] then
    timeout = 0
  elseif timers[1] then
    timeout = math.max(0, math.ceil((timers[1].at - __wlo_aio_now()) * 1000))
  end
  local fds = __wlo_ffi.new("__wlo_aio_pollfd_t[?]", #waits)
  for i, entry in ipairs(waits) do
    fds[i - 1].fd, fds[i - 1].events = entry.fd, entry.events
  end
  local count = __wlo_ffi.C.__wlo_c_aio_poll(fds, #waits, timeout)
  -- Like host.lua's __wlo_wait_fd, a failed poll reports every descriptor
  -- ready, so each operation meets the failure itself.
  local failed = count < 0 and __wlo_ffi.errno() ~= __wlo_aio_EINTR
  for i, entry in ipairs(waits) do
    if failed or fds[i - 1].revents ~= 0 then
      __wlo_aio_wake(entry.task, entry.wait, true)
    end
  end

  local now = __wlo_aio_now()
  while timers[1] and timers[1].at <= now do
    local timer = __wlo_aio_pop_timer()
    __wlo_aio_wake(timer.task, timer.wait, false)
  end
end

-- Records `task`'s outcome, the first failure of its group, and wakes the
-- tasks waiting for it.
local function __wlo_aio_finish(task, ok, value)
  if ok then
    task.state, task.value = "done", value
  elseif value == __wlo_cancel then
    task.state = "cancelled"
  else
    task.state, task.error = "failed", value
  end
  local group = task.group
  if group then
    group.count = group.count - 1
    if task.state == "failed" and not group.failure then
      group.failure = value
      __wlo_aio_request(group)
    end
    if group.count == 0 and group.joiner then
      __wlo_aio_wake(group.joiner, group.join_wait)
    end
  end
  for _, waiter in ipairs(task.waiters) do
    __wlo_aio_wake(waiter[1], waiter[2])
  end
  task.waiters = nil
end

-- Schedules `body` as a task in `group`, which is nil for the root task.
-- Errors are caught inside the coroutine, so their frames stop at the task's
-- first frame.
local function __wlo_aio_spawn(body, group, location)
  local task = { __wlo_record = "aio.Task", state = "running", scope = group, group = group,
    location = location, waiters = {} }
  task.co = coroutine.create(function()
    __wlo_aio_finish(task, xpcall(body, __wlo_catch))
  end)
  __wlo_aio_ready[#__wlo_aio_ready + 1] = task
  return task
end

-- The outcome of finished task `task`, observed at `site`.
local function __wlo_aio_outcome(task, site)
  if task.state == "done" then
    return task.value
  elseif task.state == "failed" then
    error(task.error, 0)
  end
  __wlo_fail("RuntimeError", "task was cancelled", site)
end

function __wlo_aio_task_group(site)
  return { __wlo_record = "aio.TaskGroup", state = "inactive", count = 0 }
end

function __wlo_aio_group_enter(group, site)
  if group.state ~= "inactive" then
    __wlo_fail("RuntimeError", "task group was already entered", site)
  end
  local task = __wlo_aio_current
  group.state, group.parent, task.scope = "active", task.scope, group
end

-- Joins `group` after its body departs with `code` and `value`, as
-- __wlo_try reports them, and returns the departure to continue with: the
-- group's failure, an outer request, nothing for its own absorbed stop, or
-- the body's own departure.
function __wlo_aio_group_exit(group, code, value)
  local task = __wlo_aio_current
  task.scope = group.parent
  if code == "raise" and not group.failure then
    group.failure = value
    __wlo_aio_request(group)
  end
  while group.count > 0 do
    local _, id = __wlo_aio_wait(false)
    group.joiner, group.join_wait = task, id
    coroutine.yield()
  end
  group.state = "exited"
  if group.failure then
    return "raise", group.failure
  elseif __wlo_aio_pending(task) then
    return "cancel", __wlo_cancel
  elseif code == "cancel" then
    return nil
  end
  return code, value
end

function __wlo_aio_group_start(group, c, site)
  if group.state ~= "active" or group.cancelled then
    __wlo_fail("RuntimeError", "task group is not accepting tasks", site)
  end
  local body = __wlo_consume(c, site)
  group.count = group.count + 1
  return __wlo_aio_spawn(body, group, __wlo_sites[site])
end

function __wlo_aio_group_cancel(group, site)
  if group.state ~= "active" then
    __wlo_fail("RuntimeError", "task group is not active", site)
  end
  __wlo_aio_request(group)
end

function __wlo_aio_task_result(task, site)
  if task.state == "running" then
    __wlo_fail("RuntimeError", "task is not finished", site)
  end
  return __wlo_aio_outcome(task, site)
end

function __wlo_aio_await_task(task, site)
  __wlo_aio_checkpoint()
  while task.state == "running" do
    local waiter, id = __wlo_aio_wait(true)
    task.waiters[#task.waiters + 1] = { waiter, id }
    coroutine.yield()
    __wlo_aio_checkpoint()
  end
  return __wlo_aio_outcome(task, site)
end

-- The current task's scope, saved before a protected block and restored
-- after it. Setting it to nil protects a `finally` or resource exit.
function __wlo_aio_scope()
  return __wlo_aio_current.scope
end

function __wlo_aio_set_scope(scope)
  __wlo_aio_current.scope = scope
end

-- Suspends the current task for at least `seconds`; 0 still lets every other
-- ready task run first.
function __wlo_aio_sleep(seconds)
  __wlo_aio_checkpoint()
  local task, id = __wlo_aio_wait(true)
  __wlo_aio_push_timer({ at = __wlo_aio_now() + seconds, task = task, wait = id })
  coroutine.yield()
  __wlo_aio_checkpoint()
end

-- host.lua's __wlo_wait_fd for tasks: suspends the current task until `fd` is
-- ready for the poll `events`, returning true, or until the monotonic
-- `deadline` passes, returning false. A request delivered while it waits is
-- raised here; the operation calling it checks for one before it acts.
function __wlo_aio_wait_fd(fd, events, deadline)
  local task, id = __wlo_aio_wait(true)
  local waits = __wlo_aio_fd_waits
  waits[#waits + 1] = { fd = fd, events = events, task = task, wait = id }
  if deadline then
    __wlo_aio_push_timer({ at = deadline, task = task, wait = id })
  end
  local ready = coroutine.yield()
  __wlo_aio_checkpoint()
  return ready
end

-- Runs `body` as the root task until it finishes, then returns its value or
-- raises its exception. Raises an uncatchable failure if the root task can
-- never finish because nothing can wake any task.
function __wlo_aio_run(body)
  __wlo_aio_ready, __wlo_aio_timers, __wlo_aio_fd_waits, __wlo_aio_waiting = {}, {}, {}, {}
  local root = __wlo_aio_spawn(body)
  while true do
    -- Tasks woken while this batch runs wait for the next one, after the
    -- loop has polled, so timers and descriptors are never starved.
    local batch = __wlo_aio_ready
    __wlo_aio_ready = {}
    for _, task in ipairs(batch) do
      __wlo_aio_current, __wlo_task_location = task, task.location
      assert(coroutine.resume(task.co, task.signal))
    end
    __wlo_aio_current, __wlo_task_location = nil, nil
    if root.state ~= "running" then
      break
    end
    __wlo_aio_poll()
  end
  if root.state == "failed" then
    error(root.error, 0)
  end
  return root.value
end

-- `aio.sleep`: a coroutine that checks `seconds` as `time.sleep` does once it
-- is awaited, then sleeps.
function __wlo_aio_sleep_coroutine(seconds, site)
  return __wlo_coroutine(function()
    if not (seconds >= 0 and seconds < math.huge) then
      __wlo_fail("ValueError", "sleep length must be finite and nonnegative", site)
    end
    __wlo_aio_sleep(seconds)
  end)
end
