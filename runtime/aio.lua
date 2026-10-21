-- The async event loop, inlined after runtime/core.lua into programs that call
-- its helpers, which are the functions declared without `local`. A task is a
-- Lua coroutine; it suspends by yielding to the loop, which resumes ready
-- tasks in the order they became ready and waits on timers and descriptors
-- with poll.

__wlo_ffi.cdef([[
typedef struct { int fd; short events; short revents; } __wlo_aio_pollfd_t;
int __wlo_c_aio_poll(__wlo_aio_pollfd_t *fds, unsigned long count, int timeout) __asm__("poll");
]])

local __wlo_aio_EINTR = 4

local __wlo_aio_current -- the running task
local __wlo_aio_ready -- tasks to resume, in the order they became ready
local __wlo_aio_timers -- a min-heap of { at, task, wait } by time, then wait id
local __wlo_aio_fd_waits -- { fd, events, task, wait } entries
local __wlo_aio_last_wait = 0

local function __wlo_aio_now()
  return __wlo_clock(__wlo_CLOCK_MONOTONIC)
end

-- Starts a wait for the current task and returns the task and the wait's id.
-- Ids increase across all tasks, so an id also orders timers set at the same
-- time. A task's `wait` is nil while it runs or is queued, so a waker for a
-- finished wait is ignored.
local function __wlo_aio_wait()
  __wlo_aio_last_wait = __wlo_aio_last_wait + 1
  __wlo_aio_current.wait = __wlo_aio_last_wait
  return __wlo_aio_current, __wlo_aio_last_wait
end

-- Queues `task` to resume with `signal` if it is still in wait `id`.
local function __wlo_aio_wake(task, id, signal)
  if task.wait == id then
    task.wait, task.signal = nil, signal
    __wlo_aio_ready[#__wlo_aio_ready + 1] = task
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

-- Schedules `body` as a new task. The task's state becomes "done" with its
-- `value` or "failed" with its `error`. Errors are caught inside the
-- coroutine, so their frames stop at the task's root.
function __wlo_aio_start(body)
  local task = { state = "running" }
  task.co = coroutine.create(function()
    local ok, value = xpcall(body, __wlo_catch)
    if ok then
      task.state, task.value = "done", value
    else
      task.state, task.error = "failed", value
    end
  end)
  __wlo_aio_ready[#__wlo_aio_ready + 1] = task
  return task
end

-- Suspends the current task for at least `seconds`; 0 still lets every other
-- ready task run first.
function __wlo_aio_sleep(seconds)
  local task, id = __wlo_aio_wait()
  __wlo_aio_push_timer({ at = __wlo_aio_now() + seconds, task = task, wait = id })
  coroutine.yield()
end

-- host.lua's __wlo_wait_fd for tasks: suspends the current task until `fd` is
-- ready for the poll `events`, returning true, or until the monotonic
-- `deadline` passes, returning false.
function __wlo_aio_wait_fd(fd, events, deadline)
  local task, id = __wlo_aio_wait()
  local waits = __wlo_aio_fd_waits
  waits[#waits + 1] = { fd = fd, events = events, task = task, wait = id }
  if deadline then
    __wlo_aio_push_timer({ at = deadline, task = task, wait = id })
  end
  return coroutine.yield()
end

-- Runs `body` as the root task until it finishes, then returns its value or
-- raises its exception. Raises an uncatchable failure if the root task can
-- never finish because nothing can wake any task.
function __wlo_aio_run(body)
  __wlo_aio_ready, __wlo_aio_timers, __wlo_aio_fd_waits = {}, {}, {}
  local root = __wlo_aio_start(body)
  while true do
    -- Tasks woken while this batch runs wait for the next one, after the
    -- loop has polled, so timers and descriptors are never starved.
    local batch = __wlo_aio_ready
    __wlo_aio_ready = {}
    for _, task in ipairs(batch) do
      __wlo_aio_current = task
      assert(coroutine.resume(task.co, task.signal))
    end
    __wlo_aio_current = nil
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
