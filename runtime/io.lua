-- io.File handles, inlined after runtime/core.lua into programs that use them.
-- A handle is shared by all its aliases, so closing it closes them all. The
-- standard handles borrow io.stdin, io.stdout, and io.stderr, sharing their
-- buffers with input, print, and sys.eprint. The helpers are the functions
-- declared without `local`.

local function __wlo_handle(file, path, mode, borrowed)
  return { __wlo_record = "io.File", file = file, path = path, mode = mode, borrowed = borrowed, closed = false }
end

local __wlo_standard = {
  stdin = __wlo_handle(io.stdin, "<stdin>", "r", true),
  stdout = __wlo_handle(io.stdout, "<stdout>", "w", true),
  stderr = __wlo_handle(io.stderr, "<stderr>", "w", true),
}

-- Checks that `handle` is open and, for `reading` true or false, readable or
-- writable.
local function __wlo_usable(handle, reading, site)
  if handle.closed then
    __wlo_fail("ValueError", "I/O operation on closed file", site)
  elseif reading and handle.mode ~= "r" then
    __wlo_fail("ValueError", "file is not open for reading", site)
  elseif not reading and handle.mode == "r" then
    __wlo_fail("ValueError", "file is not open for writing", site)
  end
end

local function __wlo_io_fail(action, handle, err, site)
  __wlo_fail("OSError", "cannot " .. action .. " " .. handle.path .. ": " .. tostring(err), site)
end

function __wlo_open(path, mode, site)
  if mode ~= "r" and mode ~= "w" and mode ~= "a" then
    __wlo_fail("ValueError", "invalid mode '" .. mode .. "'", site)
  elseif path:find("\0", 1, true) then
    __wlo_fail("ValueError", "path contains a NUL character", site)
  end
  local file, err = io.open(path, mode .. "b")
  if not file then
    -- io.open reports "<path>: <reason>".
    __wlo_fail("OSError", "cannot open " .. path .. ": " .. err:sub(#path + 3), site)
  end
  return __wlo_handle(file, path, mode, false)
end

function __wlo_stdin(site)
  return __wlo_standard.stdin
end

function __wlo_stdout(site)
  return __wlo_standard.stdout
end

function __wlo_stderr(site)
  return __wlo_standard.stderr
end

function __wlo_file_read(handle, size, site)
  __wlo_usable(handle, true, site)
  if size <= 0 then
    __wlo_fail("ValueError", "read size must be positive", site)
  end
  local data, err = handle.file:read(size)
  if err then
    __wlo_io_fail("read", handle, err, site)
  end
  return { __wlo_octets = data or "" }
end

-- The line is consumed even when it is not valid UTF-8.
function __wlo_file_readline(handle, site)
  __wlo_usable(handle, true, site)
  local line, err = __wlo_read_line(handle.file)
  if err then
    __wlo_io_fail("read", handle, err, site)
  end
  if line and not __wlo_valid_utf8(line) then
    __wlo_fail("ValueError", "invalid UTF-8", site)
  end
  return line
end

local function __wlo_write_octets(handle, octets, site)
  __wlo_usable(handle, false, site)
  local ok, err = handle.file:write(octets)
  if not ok then
    __wlo_io_fail("write", handle, err, site)
  end
end

function __wlo_file_write(handle, data, site)
  __wlo_write_octets(handle, data.__wlo_octets, site)
end

function __wlo_file_write_text(handle, text, site)
  __wlo_write_octets(handle, text, site)
end

function __wlo_file_flush(handle, site)
  if handle.closed then
    __wlo_fail("ValueError", "I/O operation on closed file", site)
  end
  local ok, err = handle.file:flush()
  if not ok then
    __wlo_io_fail("write", handle, err, site)
  end
end

-- The handle is closed even when closing the file fails.
function __wlo_file_close(handle, site)
  if handle.borrowed then
    __wlo_fail("ValueError", "cannot close a standard stream", site)
  elseif handle.closed then
    return
  end
  handle.closed = true
  local ok, err = handle.file:close()
  if not ok then
    __wlo_io_fail("close", handle, err, site)
  end
end
