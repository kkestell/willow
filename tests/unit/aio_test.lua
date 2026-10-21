local ffi = require("ffi")
local runtime = require("compiler.runtime")

local eq = require("tests.support").eq

local A = {}
local names = { "aio_run", "aio_sleep", "aio_wait_fd", "aio_task_group", "aio_group_enter", "aio_group_exit",
  "aio_group_start", "aio_group_cancel", "aio_task_result", "aio_await_task", "aio_scope", "aio_set_scope",
  "aio_listen", "aio_connect_coroutine", "aio_listener_local_port", "aio_listener_accept",
  "aio_listener_close", "aio_connection_recv", "aio_connection_sendall", "aio_connection_close",
  "coroutine", "await", "try", "fail", "monotonic", "report", "sites", "paths" }
local helpers, references = {}, {}
for i, name in ipairs(names) do
  helpers[name] = true
  references[i] = "__wlo_" .. name
end
for i, value in ipairs({ runtime.load(helpers, references) }) do
  A[names[i]:gsub("^aio_", "")] = value
end

ffi.cdef([[
int __wlo_test_pipe(int fds[2]) __asm__("pipe");
long __wlo_test_write(int fd, const void *buffer, size_t size) __asm__("write");
int __wlo_test_close(int fd) __asm__("close");
typedef struct { uint64_t cur, max; } __wlo_test_rlimit_t;
int __wlo_test_getrlimit(int resource, __wlo_test_rlimit_t *limit) __asm__("getrlimit");
int __wlo_test_setrlimit(int resource, const __wlo_test_rlimit_t *limit) __asm__("setrlimit");
int __wlo_test_fcntl(int fd, int command, ...) __asm__("fcntl");
]])

local POLLIN = 1

-- The number of open descriptors below 256: F_GETFD fails only for a closed
-- one.
local function open_fds()
  local count = 0
  for fd = 0, 256 do
    if ffi.C.__wlo_test_fcntl(fd, 1, 0) >= 0 then
      count = count + 1
    end
  end
  return count
end

local run = A.run

local function start(group, body)
  return A.group_start(group, A.coroutine(body))
end

local function fail(message)
  A.fail("ValueError", message)
end

-- The code emitted for `async with group: body`, returning the departure.
local function async_with(group, body)
  A.group_enter(group)
  local code, value = A.try(body)
  code, value = A.group_exit(group, code, value)
  if code == "raise" or code == "cancel" then
    error(value, 0)
  end
  return code, value
end

-- The code emitted for `try: body finally: cleanup` in an async function.
local function try_finally(body, cleanup)
  local scope = A.scope()
  local code, value = A.try(body)
  A.set_scope(nil)
  cleanup()
  A.set_scope(scope)
  if code == "raise" or code == "cancel" then
    error(value, 0)
  end
  return code, value
end

-- Runs `body` and returns the message of the RuntimeError it raises.
local function runtime_error(body)
  local code, err = A.try(body)
  eq("raise", code)
  eq("RuntimeError", err.__wlo_class)
  return err.message
end

local tests = {}

function tests.ready_tasks_run_in_fifo_order()
  local log = {}
  local function worker(name)
    return function()
      log[#log + 1] = name .. "1"
      A.sleep(0)
      log[#log + 1] = name .. "2"
    end
  end
  eq(42, run(function()
    local group = A.task_group()
    async_with(group, function()
      start(group, worker("a"))
      start(group, worker("b"))
      start(group, worker("c"))
      A.sleep(0)
      log[#log + 1] = "body"
    end)
    return 42
  end))
  eq("a1 b1 c1 body a2 b2 c2", table.concat(log, " "))
end

function tests.timers_fire_in_deadline_order()
  local log = {}
  run(function()
    local group = A.task_group()
    async_with(group, function()
      for _, timer in ipairs({ { "a", 0.03 }, { "b", 0.01 }, { "c", 0.02 }, { "d", 0.01 } }) do
        start(group, function()
          A.sleep(timer[2])
          log[#log + 1] = timer[1]
        end)
      end
    end)
  end)
  eq("b d c a", table.concat(log, " "))
end

function tests.fd_wait_suspends_until_ready_deadline_or_request()
  local fds = ffi.new("int[2]")
  assert(ffi.C.__wlo_test_pipe(fds) == 0)
  local log = {}
  run(function()
    local group = A.task_group()
    async_with(group, function()
      start(group, function()
        A.sleep(0.01)
        log[#log + 1] = "write"
        ffi.C.__wlo_test_write(fds[1], "x", 1)
      end)
      local ready = A.wait_fd(fds[0], POLLIN, nil)
      log[#log + 1] = tostring(ready)
    end)
  end)
  eq("write true", table.concat(log, " "))
  ffi.C.__wlo_test_close(fds[0])
  ffi.C.__wlo_test_close(fds[1])

  assert(ffi.C.__wlo_test_pipe(fds) == 0)
  local deadline = A.monotonic() + 0.02
  eq(false, run(function()
    return A.wait_fd(fds[0], POLLIN, deadline)
  end))
  assert(A.monotonic() >= deadline)

  -- A request ends a wait with no deadline.
  run(function()
    local group = A.task_group()
    async_with(group, function()
      start(group, function()
        A.wait_fd(fds[0], POLLIN, nil)
        log[#log + 1] = "not reached"
      end)
      A.sleep(0)
      A.group_cancel(group)
    end)
  end)
  eq("write true", table.concat(log, " "))
  ffi.C.__wlo_test_close(fds[0])
  ffi.C.__wlo_test_close(fds[1])
end

-- poll fails once its entries exceed the open-file limit, so waits on one
-- descriptor must share an entry.
function tests.many_waits_on_one_fd_reach_their_deadlines()
  local RLIMIT_NOFILE = ffi.os == "OSX" and 8 or 7
  local fds = ffi.new("int[2]")
  assert(ffi.C.__wlo_test_pipe(fds) == 0)
  local saved = ffi.new("__wlo_test_rlimit_t")
  assert(ffi.C.__wlo_test_getrlimit(RLIMIT_NOFILE, saved) == 0)
  local lowered = ffi.new("__wlo_test_rlimit_t", 16, saved.max)
  assert(ffi.C.__wlo_test_setrlimit(RLIMIT_NOFILE, lowered) == 0)
  local results = {}
  local ok, err = pcall(run, function()
    local deadline = A.monotonic() + 0.05
    local group = A.task_group()
    async_with(group, function()
      for i = 1, 40 do
        start(group, function()
          results[i] = A.wait_fd(fds[0], POLLIN, deadline)
        end)
      end
    end)
  end)
  ffi.C.__wlo_test_setrlimit(RLIMIT_NOFILE, saved)
  ffi.C.__wlo_test_close(fds[0])
  ffi.C.__wlo_test_close(fds[1])
  assert(ok, err)
  for i = 1, 40 do
    eq(false, results[i])
  end
end

function tests.root_failure_is_raised_unchanged()
  local failure = { __wlo_class = "ValueError", message = "bad" }
  local ok, err = pcall(run, function()
    A.sleep(0)
    error(failure, 0)
  end)
  eq(false, ok)
  eq(failure, err)
end

function tests.deadlock_is_reported()
  local fds = ffi.new("int[2]")
  assert(ffi.C.__wlo_test_pipe(fds) == 0)
  ffi.C.__wlo_test_write(fds[1], "x", 1)
  local started = A.monotonic()
  local ok, err = pcall(run, function()
    -- A wait that ended leaves its deadline timer behind; it must not delay
    -- the report.
    A.wait_fd(fds[0], POLLIN, A.monotonic() + 60)
    local group = A.task_group()
    async_with(group, function()
      local task
      task = start(group, function()
        A.await_task(task)
      end)
    end)
  end)
  ffi.C.__wlo_test_close(fds[0])
  ffi.C.__wlo_test_close(fds[1])
  eq(false, ok)
  eq("deadlock: all tasks are waiting", err.message)
  eq(nil, err.__wlo_class)
  eq("error: deadlock: all tasks are waiting", A.report(err))
  assert(A.monotonic() - started < 1)
end

function tests.group_states_and_messages()
  run(function()
    local group = A.task_group()
    local c = A.coroutine(function()
      return 1
    end)
    eq("task group is not accepting tasks", runtime_error(function()
      A.group_start(group, c)
    end))
    eq("task group is not active", runtime_error(function()
      A.group_cancel(group)
    end))
    async_with(group, function()
      eq("task group was already entered", runtime_error(function()
        A.group_enter(group)
      end))
      A.group_cancel(group)
      A.group_cancel(group)
      eq("task group is not accepting tasks", runtime_error(function()
        A.group_start(group, c)
      end))
    end)
    eq("task group is not accepting tasks", runtime_error(function()
      A.group_start(group, c)
    end))
    eq("task group is not active", runtime_error(function()
      A.group_cancel(group)
    end))
    -- Rejected starts did not consume the coroutine.
    eq(1, A.await(c))
  end)
end

function tests.task_results_and_awaits()
  run(function()
    local failure = { __wlo_class = "ValueError", message = "bad" }
    local group = A.task_group()
    local done, failed
    local code, err = A.try(function()
      async_with(group, function()
        done = start(group, function()
          return 7
        end)
        eq("task is not finished", runtime_error(function()
          A.task_result(done)
        end))
        eq(7, A.await_task(done))
        eq(7, A.await_task(done))
        failed = start(group, function()
          error(failure, 0)
        end)
        A.await_task(failed)
      end)
    end)
    eq("raise", code)
    eq(failure, err)
    eq(7, A.task_result(done))
    eq(failure, select(2, A.try(function()
      A.task_result(failed)
    end)))

    local cancelled
    group = A.task_group()
    async_with(group, function()
      cancelled = start(group, function()
        A.sleep(10)
      end)
      A.sleep(0)
      A.group_cancel(group)
    end)
    eq("task was cancelled", runtime_error(function()
      A.task_result(cancelled)
    end))
    eq("task was cancelled", runtime_error(function()
      A.await_task(cancelled)
    end))
  end)
end

function tests.join_waits_for_children_started_while_joining()
  local log = {}
  run(function()
    local group = A.task_group()
    async_with(group, function()
      start(group, function()
        A.sleep(0.01)
        start(group, function()
          A.sleep(0.01)
          log[#log + 1] = "grandchild"
        end)
        log[#log + 1] = "child"
      end)
      log[#log + 1] = "body"
    end)
    log[#log + 1] = "after"
  end)
  eq("body child grandchild after", table.concat(log, " "))
end

function tests.first_failure_stops_the_group()
  local log = {}
  local _, err = A.try(function()
    run(function()
      local group = A.task_group()
      async_with(group, function()
        start(group, function()
          try_finally(function()
            A.sleep(10)
          end, function()
            log[#log + 1] = "cleanup"
            fail("second")
          end)
        end)
        start(group, function()
          A.sleep(0)
          fail("first")
        end)
        A.sleep(10)
        log[#log + 1] = "not reached"
      end)
    end)
  end)
  eq("first", err.message)
  eq("cleanup", table.concat(log, " "))
end

function tests.awaiting_a_finished_task_is_a_checkpoint()
  local log = {}
  run(function()
    local group = A.task_group()
    async_with(group, function()
      local task = start(group, function()
        return 1
      end)
      A.sleep(0)
      A.group_cancel(group)
      log[#log + 1] = "cancel returned"
      A.await_task(task)
      log[#log + 1] = "not reached"
    end)
  end)
  eq("cancel returned", table.concat(log, " "))
end

function tests.admitted_task_enters_its_body_before_a_checkpoint()
  local log = {}
  run(function()
    local group = A.task_group()
    async_with(group, function()
      local task = start(group, function()
        log[#log + 1] = "entered"
        A.sleep(0)
        log[#log + 1] = "not reached"
      end)
      A.group_cancel(group)
    end)
  end)
  eq("entered", table.concat(log, " "))
end

-- Admission depends only on the group's own state, so an outer request does
-- not stop an inner group from starting a task.
function tests.inner_group_admits_tasks_under_an_outer_request()
  local log = {}
  run(function()
    local outer = A.task_group()
    async_with(outer, function()
      A.group_cancel(outer)
      local inner = A.task_group()
      async_with(inner, function()
        start(inner, function()
          log[#log + 1] = "entered"
          A.sleep(0)
          log[#log + 1] = "not reached"
        end)
      end)
      log[#log + 1] = "not reached"
    end)
    log[#log + 1] = "absorbed"
  end)
  eq("entered absorbed", table.concat(log, " "))
end

-- A failure that is not an exception, such as a stack overflow, ends the
-- program at once; sibling cleanup does not run.
function tests.fatal_failure_in_a_task_skips_group_cleanup()
  local log = {}
  local fatal = { message = "fatal" }
  local ok, err = pcall(run, function()
    local group = A.task_group()
    async_with(group, function()
      start(group, function()
        try_finally(function()
          A.sleep(10)
        end, function()
          log[#log + 1] = "cleanup"
        end)
      end)
      start(group, function()
        A.sleep(0)
        error(fatal, 0)
      end)
      A.sleep(10)
    end)
  end)
  eq(false, ok)
  eq(fatal, err)
  eq("", table.concat(log, " "))
end

function tests.stop_during_join_preserves_a_pending_return()
  eq(42, run(function()
    local group = A.task_group()
    local code, value = async_with(group, function()
      start(group, function()
        A.sleep(0.01)
        A.group_cancel(group)
      end)
      start(group, function()
        A.sleep(10)
      end)
      return "return", 42
    end)
    eq("return", code)
    return value
  end))
end

-- The scenarios below are agents/prototypes/async/runtime/scenarios.lua.

function tests.inner_group_does_not_absorb_an_outer_request()
  local log = {}
  run(function()
    local outer = A.task_group()
    async_with(outer, function()
      local inner = A.task_group()
      start(outer, function()
        A.sleep(0.01)
        A.group_cancel(inner)
        A.group_cancel(outer)
        log[#log + 1] = "cancelled both"
      end)
      async_with(inner, function()
        start(inner, function()
          try_finally(function()
            A.sleep(10)
          end, function()
            A.sleep(0.01)
            log[#log + 1] = "inner cleanup"
          end)
        end)
        A.sleep(10)
        log[#log + 1] = "not reached"
      end)
      log[#log + 1] = "not reached after inner"
    end)
    log[#log + 1] = "outer absorbed"
  end)
  eq("cancelled both, inner cleanup, outer absorbed", table.concat(log, ", "))
end

function tests.request_during_cleanup_of_a_return_waits_for_it()
  local log = {}
  run(function()
    local group = A.task_group()
    local code, value = async_with(group, function()
      start(group, function()
        A.sleep(0.01)
        A.group_cancel(group)
      end)
      return try_finally(function()
        return "return", 42
      end, function()
        A.sleep(0.03)
        log[#log + 1] = "cleanup finished"
      end)
    end)
    log[#log + 1] = code .. " " .. value
  end)
  eq("cleanup finished, return 42", table.concat(log, ", "))
end

function tests.group_inside_protected_cleanup()
  local log = {}
  run(function()
    local outer = A.task_group()
    async_with(outer, function()
      start(outer, function()
        A.sleep(0.01)
        A.group_cancel(outer)
      end)
      try_finally(function() end, function()
        local inner = A.task_group()
        async_with(inner, function()
          start(inner, function()
            A.sleep(0.02)
            log[#log + 1] = "protected child finished"
          end)
          start(inner, function()
            A.sleep(0.03)
            A.group_cancel(inner)
          end)
          A.sleep(10)
          log[#log + 1] = "not reached"
        end)
        log[#log + 1] = "inner absorbed its stop"
      end)
      log[#log + 1] = "after cleanup"
      A.sleep(0)
      log[#log + 1] = "not reached"
    end)
    log[#log + 1] = "outer absorbed"
  end)
  eq("protected child finished, inner absorbed its stop, after cleanup, outer absorbed", table.concat(log, ", "))
end

function tests.inner_failure_takes_precedence_over_an_outer_request()
  local log = {}
  run(function()
    local outer = A.task_group()
    async_with(outer, function()
      local code, err = A.try(function()
        local inner = A.task_group()
        async_with(inner, function()
          start(inner, function()
            try_finally(function()
              A.sleep(10)
            end, function()
              A.sleep(0.01)
              fail("boom")
            end)
          end)
          A.sleep(0)
          A.group_cancel(outer)
          A.sleep(10)
        end)
      end)
      log[#log + 1] = code .. " " .. err.message
      -- The outer request survives the catch.
      A.sleep(0)
      log[#log + 1] = "not reached"
    end)
    log[#log + 1] = "outer absorbed"
  end)
  eq("raise boom, outer absorbed", table.concat(log, ", "))
end

function tests.task_failures_report_where_the_task_started()
  A.paths[1] = "server.wlo"
  A.sites[1] = { 31, 17, 1 }
  A.sites[2] = { 12, 9, 1 }
  local ok, err = pcall(run, function()
    local group = A.task_group()
    async_with(group, function()
      A.group_start(group, A.coroutine(function()
        A.fail("ValueError", "bad request", 2)
      end), 1)
    end)
  end)
  eq(false, ok)
  eq("server.wlo:12:9: error: ValueError: bad request\n  in task started at server.wlo:31:17", A.report(err))
end

-- A connected client and the connection its listener accepted. Call it from a
-- task, since the operations suspend.
local function aio_pair()
  local listener = A.listen("127.0.0.1", 0, 16, 0)
  local client = A.await(A.connect_coroutine("127.0.0.1", A.listener_local_port(listener, 0), 5.0, 0), 0)
  local server = A.await(A.listener_accept(listener, 5.0, 0), 0)
  return listener, client, server
end

-- Runs `body` and returns the class and message of the exception it raises.
local function raised(body)
  local code, err = A.try(body)
  eq("raise", code)
  return err.__wlo_class, err.message
end

function tests.aio_one_operation_per_direction()
  run(function()
    local listener, client, server = aio_pair()
    local group = A.task_group()
    local code, err = A.try(function()
      async_with(group, function()
        start(group, function()
          A.await(A.connection_recv(server, 10, nil, 0), 0)
        end)
        A.sleep(0)
        eq("recv is already in progress", runtime_error(function()
          A.await(A.connection_recv(server, 10, nil, 0), 0)
        end))
        -- The other direction is free while a recv is unfinished.
        A.await(A.connection_sendall(server, { __wlo_octets = "hi" }, 5.0, 0), 0)
        -- Closing wakes the recv, which reports the closed handle.
        A.connection_close(server, 0)
      end)
    end)
    eq("raise", code)
    eq("I/O operation on closed connection", err.message)
    A.connection_close(client, 0)
    A.listener_close(listener, 0)
  end)
end

function tests.aio_one_sendall_at_a_time_and_cancellation_breaks_the_connection()
  run(function()
    local listener, client, server = aio_pair()
    local big = { __wlo_octets = string.rep("x", 16 * 1024 * 1024) }
    local group = A.task_group()
    async_with(group, function()
      start(group, function()
        A.await(A.connection_sendall(server, big, 5.0, 0), 0)
      end)
      A.sleep(0)
      eq("sendall is already in progress", runtime_error(function()
        A.await(A.connection_sendall(server, { __wlo_octets = "y" }, 5.0, 0), 0)
      end))
      A.group_cancel(group)
    end)
    -- The cancelled send may have delivered part of the data.
    local class, message = raised(function()
      A.await(A.connection_sendall(server, { __wlo_octets = "y" }, 5.0, 0), 0)
    end)
    eq("ValueError", class)
    eq("connection is unusable after a failed send", message)
    A.connection_close(server, 0)
    A.connection_close(client, 0)
    A.listener_close(listener, 0)
  end)
end

function tests.aio_close_wakes_a_pending_accept()
  run(function()
    local listener = A.listen("127.0.0.1", 0, 16, 0)
    local group = A.task_group()
    local code, err = A.try(function()
      async_with(group, function()
        start(group, function()
          A.await(A.listener_accept(listener, nil, 0), 0)
        end)
        A.sleep(0)
        A.listener_close(listener, 0)
      end)
    end)
    eq("raise", code)
    eq("I/O operation on closed listener", err.message)
  end)
end

function tests.aio_cancelled_connect_closes_its_socket()
  run(function()
    -- A listener that never accepts: once its backlog is full, further
    -- connects stay pending.
    local listener = A.listen("127.0.0.1", 0, 1, 0)
    local port = A.listener_local_port(listener, 0)
    local before = open_fds()
    local connected = {}
    local group = A.task_group()
    async_with(group, function()
      for _ = 1, 8 do
        start(group, function()
          local connection = A.await(A.connect_coroutine("127.0.0.1", port, 30.0, 0), 0)
          connected[#connected + 1] = connection
        end)
      end
      A.sleep(0.05)
      eq(before + 8, open_fds())
      assert(#connected < 8, "no connect stayed pending")
      A.group_cancel(group)
    end)
    for _, connection in ipairs(connected) do
      A.connection_close(connection, 0)
    end
    eq(before, open_fds())
    A.listener_close(listener, 0)
  end)
end

-- A send blocked on a full buffer and a recv share one descriptor; data for
-- the recv wakes it while the send stays blocked.
function tests.aio_recv_and_sendall_wait_at_the_same_time()
  run(function()
    local listener, client, server = aio_pair()
    local big = { __wlo_octets = string.rep("x", 16 * 1024 * 1024) }
    local log = {}
    local group = A.task_group()
    async_with(group, function()
      start(group, function()
        A.await(A.connection_sendall(server, big, 5.0, 0), 0)
        log[#log + 1] = "sent"
      end)
      start(group, function()
        local data = A.await(A.connection_recv(server, 10, 5.0, 0), 0)
        log[#log + 1] = "received " .. data.__wlo_octets
      end)
      A.sleep(0.01)
      A.await(A.connection_sendall(client, { __wlo_octets = "ping" }, 5.0, 0), 0)
      A.sleep(0.01)
      eq("received ping", table.concat(log, " "))
      local total = 0
      while total < #big.__wlo_octets do
        total = total + #A.await(A.connection_recv(client, 1024 * 1024, 5.0, 0), 0).__wlo_octets
      end
    end)
    eq("received ping sent", table.concat(log, " "))
    A.connection_close(server, 0)
    A.connection_close(client, 0)
    A.listener_close(listener, 0)
  end)
end

return tests
