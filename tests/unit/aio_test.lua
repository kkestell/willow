local ffi = require("ffi")
local runtime = require("compiler.runtime")

local eq = require("tests.support").eq

local run, start, sleep, wait_fd, monotonic, report = runtime.load({ aio_run = true, monotonic = true },
  { "__wlo_aio_run", "__wlo_aio_start", "__wlo_aio_sleep", "__wlo_aio_wait_fd", "__wlo_monotonic", "__wlo_report" })

ffi.cdef([[
int __wlo_test_pipe(int fds[2]) __asm__("pipe");
long __wlo_test_write(int fd, const void *buffer, size_t size) __asm__("write");
int __wlo_test_close(int fd) __asm__("close");
]])

local POLLIN = 1

local tests = {}

function tests.ready_tasks_run_in_fifo_order()
  local log = {}
  local function worker(name)
    return function()
      log[#log + 1] = name .. "1"
      sleep(0)
      log[#log + 1] = name .. "2"
    end
  end
  eq(42, run(function()
    start(worker("a"))
    start(worker("b"))
    start(worker("c"))
    sleep(0)
    log[#log + 1] = "root"
    sleep(0)
    return 42
  end))
  eq("a1 b1 c1 root a2 b2 c2", table.concat(log, " "))
end

function tests.timers_fire_in_deadline_order()
  local log = {}
  run(function()
    for _, timer in ipairs({ { "a", 0.03 }, { "b", 0.01 }, { "c", 0.02 }, { "d", 0.01 } }) do
      start(function()
        sleep(timer[2])
        log[#log + 1] = timer[1]
      end)
    end
    sleep(0.05)
  end)
  eq("b d c a", table.concat(log, " "))
end

function tests.fd_wait_suspends_until_ready_or_deadline()
  local fds = ffi.new("int[2]")
  assert(ffi.C.__wlo_test_pipe(fds) == 0)
  local log = {}
  run(function()
    start(function()
      sleep(0.01)
      log[#log + 1] = "write"
      ffi.C.__wlo_test_write(fds[1], "x", 1)
    end)
    local ready = wait_fd(fds[0], POLLIN, nil)
    log[#log + 1] = tostring(ready)
  end)
  eq("write true", table.concat(log, " "))
  ffi.C.__wlo_test_close(fds[0])
  ffi.C.__wlo_test_close(fds[1])

  assert(ffi.C.__wlo_test_pipe(fds) == 0)
  local deadline = monotonic() + 0.02
  eq(false, run(function()
    return wait_fd(fds[0], POLLIN, deadline)
  end))
  assert(monotonic() >= deadline)
  ffi.C.__wlo_test_close(fds[0])
  ffi.C.__wlo_test_close(fds[1])
end

function tests.root_failure_is_raised_unchanged()
  local failure = { __wlo_class = "ValueError", message = "bad" }
  local ok, err = pcall(run, function()
    sleep(0)
    error(failure, 0)
  end)
  eq(false, ok)
  eq(failure, err)
end

function tests.deadlock_is_reported()
  local fds = ffi.new("int[2]")
  assert(ffi.C.__wlo_test_pipe(fds) == 0)
  ffi.C.__wlo_test_write(fds[1], "x", 1)
  local started = monotonic()
  local ok, err = pcall(run, function()
    -- A wait that ended leaves its deadline timer behind; it must not delay
    -- the report.
    wait_fd(fds[0], POLLIN, monotonic() + 60)
    start(function()
      coroutine.yield()
    end)
    coroutine.yield()
  end)
  ffi.C.__wlo_test_close(fds[0])
  ffi.C.__wlo_test_close(fds[1])
  eq(false, ok)
  eq("deadlock: all tasks are waiting", err.message)
  eq(nil, err.__wlo_class)
  eq("error: deadlock: all tasks are waiting", report(err))
  assert(monotonic() - started < 1)
end

return tests
