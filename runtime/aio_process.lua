-- `subprocess`'s async operations, inlined after runtime/core.lua into programs
-- that call them. Each is a coroutine that waits by suspending its task, and
-- the process work is host.lua's. A suspending wait watches one descriptor,
-- so a pass that moves no data waits on one of the pipes for at most 10 ms.
-- The helpers here are the functions declared without `local`.

local __wlo_aio_process_TICK = 0.01

-- `subprocess.run` for a task. Cancellation and failure kill and reap the
-- child and close the pipes, then propagate.
function __wlo_process_run_async(args, input, capture_output, cwd, env, timeout, site)
  return __wlo_coroutine(function()
    __wlo_runtime.aio_checkpoint()
    __wlo_check_timeout(timeout, site)
    local run = __wlo_runtime.run_start(args, input, capture_output, cwd, env, site)
    local deadline = timeout and __wlo_runtime.monotonic() + timeout
    local turn = 0
    local ok, result = xpcall(function()
      while true do
        local progress = __wlo_runtime.run_write(run)
        for fd in pairs(run.open) do
          progress = __wlo_runtime.run_read(run, fd) or progress
        end
        local code = __wlo_runtime.process_poll(run, site)
        if code ~= nil then
          return __wlo_runtime.run_finish(run, code)
        end
        local now = __wlo_runtime.monotonic()
        if deadline and now >= deadline then
          __wlo_runtime.run_timed_out(timeout, site)
        end
        local wait_until = now + __wlo_aio_process_TICK
        if deadline and deadline < wait_until then
          wait_until = deadline
        end
        if progress then
          __wlo_runtime.aio_sleep(0)
        else
          -- Rotate among the descriptors so none waits on another's silence.
          local fds, events = {}, {}
          if run.input_fd then
            fds[#fds + 1], events[#fds + 1] = run.input_fd, 4 -- POLLOUT
          end
          for fd in pairs(run.open) do
            fds[#fds + 1], events[#fds + 1] = fd, 1 -- POLLIN
          end
          if fds[1] then
            turn = turn % #fds + 1
            __wlo_runtime.aio_wait_fd(fds[turn], events[turn], wait_until)
          else
            __wlo_runtime.aio_sleep(wait_until - now)
          end
        end
      end
    end, __wlo_catch)
    if not ok then
      __wlo_runtime.run_abort(run)
      error(result, 0)
    end
    return result
  end)
end

-- `Process.wait` for a task. A timeout or cancellation leaves the child
-- running.
function __wlo_process_wait_async(process, timeout, site)
  return __wlo_coroutine(function()
    __wlo_runtime.aio_checkpoint()
    __wlo_check_timeout(timeout, site)
    local deadline = timeout and __wlo_runtime.monotonic() + timeout
    while true do
      local code = __wlo_runtime.process_poll(process, site)
      if code ~= nil then
        return code
      end
      local remaining = deadline and deadline - __wlo_runtime.monotonic()
      if remaining and remaining <= 0 then
        __wlo_fail("TimeoutError", "process did not exit within " .. __wlo_format_float(timeout) .. " seconds", site)
      end
      __wlo_runtime.aio_sleep(remaining and math.min(__wlo_aio_process_TICK, remaining) or __wlo_aio_process_TICK)
    end
  end)
end
