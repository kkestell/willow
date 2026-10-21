-- `aio`'s TCP handles, inlined after runtime/core.lua into programs that call
-- them. An operation is a coroutine that suspends its task, and the I/O itself
-- is host.lua's socket bodies, which take the function they wait with. The
-- helpers here are the functions declared without `local`.

-- host.lua's connection, tagged as `aio.Connection`.
local function __wlo_aio_connection(connection)
  connection.__wlo_record = "aio.Connection"
  return connection
end

-- Runs `body` as the one unfinished operation in `field` of `handle`. `what`
-- names the operation and `kind` names the handle in the errors for repeating
-- an operation and for a closed handle. `body` waits with the `wait` it is
-- given, which suspends the current task and checks the handle after every
-- wake, so closing the handle fails the operation.
local function __wlo_aio_operation(handle, field, what, kind, site, body)
  __wlo_runtime.aio_checkpoint()
  if handle[field] then
    __wlo_fail("RuntimeError", what .. " is already in progress", site)
  end
  handle[field] = true
  local function wait(fd, events, deadline)
    local ready = __wlo_runtime.aio_wait_fd(fd, events, deadline)
    if handle.closed then
      __wlo_fail("ValueError", "I/O operation on closed " .. kind, site)
    end
    return ready
  end
  local ok, value = xpcall(body, __wlo_catch, wait)
  handle[field] = nil
  if not ok then
    error(value, 0)
  end
  return value
end

-- `aio.connect`: checks for a request, then connects, waiting by suspending.
function __wlo_aio_connect_coroutine(host, port, timeout, site)
  return __wlo_coroutine(function()
    __wlo_runtime.aio_checkpoint()
    return __wlo_aio_connection(
      __wlo_runtime.socket_connect(__wlo_runtime.aio_wait_fd, host, port, timeout, site))
  end)
end

-- `aio.listen`: `net.listen` with the tag of `aio.Listener`.
function __wlo_aio_listen(host, port, backlog, site)
  local listener = __wlo_runtime.net_listen(host, port, backlog, site)
  listener.__wlo_record = "aio.Listener"
  return listener
end

function __wlo_aio_connection_recv(connection, size, timeout, site)
  return __wlo_coroutine(function()
    return __wlo_aio_operation(connection, "recv_op", "recv", "connection", site, function(wait)
      return __wlo_runtime.socket_recv(wait, connection, size, timeout, site)
    end)
  end)
end

function __wlo_aio_connection_sendall(connection, data, timeout, site)
  return __wlo_coroutine(function()
    return __wlo_aio_operation(connection, "send_op", "sendall", "connection", site, function(wait)
      return __wlo_runtime.socket_sendall(wait, connection, data, timeout, site)
    end)
  end)
end

function __wlo_aio_connection_close(connection, site)
  if not connection.closed then
    __wlo_runtime.net_connection_close(connection, site)
    __wlo_runtime.aio_wake_fd(connection.fd)
  end
end

function __wlo_aio_connection_enter(connection, site)
  return __wlo_runtime.net_connection_enter(connection, site)
end

function __wlo_aio_connection_exit(connection, error, site)
  __wlo_aio_connection_close(connection, site)
end

function __wlo_aio_listener_accept(listener, timeout, site)
  return __wlo_coroutine(function()
    return __wlo_aio_connection(
      __wlo_aio_operation(listener, "accept_op", "accept", "listener", site, function(wait)
        return __wlo_runtime.socket_accept(wait, listener, timeout, site)
      end))
  end)
end

function __wlo_aio_listener_local_port(listener, site)
  return __wlo_runtime.net_listener_local_port(listener, site)
end

function __wlo_aio_listener_close(listener, site)
  if not listener.closed then
    __wlo_runtime.net_listener_close(listener, site)
    __wlo_runtime.aio_wake_fd(listener.fd)
  end
end

function __wlo_aio_listener_enter(listener, site)
  return __wlo_runtime.net_listener_enter(listener, site)
end

function __wlo_aio_listener_exit(listener, error, site)
  __wlo_aio_listener_close(listener, site)
end
