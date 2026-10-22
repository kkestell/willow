-- `net.Reader`, inlined after runtime/core.lua into programs that call it. A
-- reader owns a connection and keeps the bytes it received beyond what a call
-- returned in `buffer`. It receives with host.lua's `net` operations. The
-- helpers here are the functions declared without `local`.

local function __wlo_reader_usable(reader, site)
  if reader.closed then
    __wlo_fail("ValueError", "I/O operation on closed reader", site)
  end
end

-- Appends the next bytes of the stream to the reader's buffer, which waits no
-- later than `deadline`. Returns false at the end of the stream. `what` and
-- `timeout` describe the call in the timeout error.
local function __wlo_reader_fill(reader, what, timeout, deadline, site)
  local remaining
  if deadline then
    remaining = deadline - __wlo_runtime.monotonic()
  end
  if remaining and remaining <= 0 then
    __wlo_fail("TimeoutError", what .. " timed out after " .. __wlo_format_float(timeout) .. " seconds", site)
  end
  local ok, chunk = xpcall(__wlo_runtime.net_connection_recv, __wlo_catch, reader.connection, 65536, remaining, site)
  if not ok then
    -- The connection's own timeout reports the time left, not the call's.
    if chunk.__wlo_class == "TimeoutError" then
      __wlo_fail("TimeoutError", what .. " timed out after " .. __wlo_format_float(timeout) .. " seconds", site)
    end
    error(chunk, 0)
  end
  reader.buffer = reader.buffer .. chunk.__wlo_octets
  return chunk.__wlo_octets ~= ""
end

local function __wlo_reader_take(reader, count)
  local data = reader.buffer:sub(1, count)
  reader.buffer = reader.buffer:sub(count + 1)
  return { __wlo_octets = data }
end

function __wlo_net_reader(connection, site)
  __wlo_runtime.net_connection_enter(connection, site)
  return { "net.Reader", connection = connection, buffer = "", closed = false }
end

function __wlo_net_reader_read_exactly(reader, size, timeout, site)
  __wlo_reader_usable(reader, site)
  if size < 0 then
    __wlo_fail("ValueError", "size must not be negative", site)
  end
  __wlo_check_timeout(timeout, site)
  local deadline = timeout and __wlo_runtime.monotonic() + timeout
  while #reader.buffer < size do
    if not __wlo_reader_fill(reader, "read_exactly", timeout, deadline, site) then
      __wlo_fail("OSError", "unexpected end of stream: expected " .. size .. " bytes, received "
        .. #reader.buffer, site)
    end
  end
  return __wlo_reader_take(reader, size)
end

function __wlo_net_reader_read_until(reader, separator, max_bytes, timeout, site)
  __wlo_reader_usable(reader, site)
  local octets = separator.__wlo_octets
  if octets == "" then
    __wlo_fail("ValueError", "separator must not be empty", site)
  elseif max_bytes < 1 then
    __wlo_fail("ValueError", "max_bytes must be positive", site)
  end
  __wlo_check_timeout(timeout, site)
  local deadline = timeout and __wlo_runtime.monotonic() + timeout
  local from = 1
  while true do
    local first, last = reader.buffer:find(octets, from, true)
    if first and last <= max_bytes then
      return __wlo_reader_take(reader, last)
    elseif first or #reader.buffer >= max_bytes then
      __wlo_fail("ValueError", "separator not found within " .. max_bytes .. " bytes", site)
    end
    -- A separator may straddle the bytes received next.
    from = math.max(1, #reader.buffer - #octets + 2)
    if not __wlo_reader_fill(reader, "read_until", timeout, deadline, site) then
      return __wlo_reader_take(reader, #reader.buffer)
    end
  end
end

function __wlo_net_reader_close(reader, site)
  if not reader.closed then
    reader.closed = true
    reader.buffer = ""
    __wlo_runtime.net_connection_close(reader.connection, site)
  end
end

function __wlo_net_reader_enter(reader, site)
  __wlo_reader_usable(reader, site)
  return reader
end

function __wlo_net_reader_exit(reader, error, site)
  __wlo_net_reader_close(reader, site)
end
