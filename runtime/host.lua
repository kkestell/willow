-- Filesystem, environment, clock, and process helpers, inlined after
-- runtime/core.lua into programs that call them. The helpers are the functions declared without
-- `local`. C functions get __wlo_c_ names so they cannot clash with
-- declarations the CLI makes in the same process.

local __wlo_OSX = __wlo_ffi.os == "OSX"
-- macOS on x64 keeps the 32-bit inode functions under the plain names.
local __wlo_INODE64 = __wlo_OSX and __wlo_ffi.arch == "x64" and "$INODE64" or ""

if __wlo_OSX then
  __wlo_ffi.cdef([[
typedef struct {
  int32_t dev; uint16_t mode; uint16_t nlink; uint64_t ino; uint32_t uid; uint32_t gid; int32_t rdev;
  int64_t atime_sec; long atime_nsec; int64_t mtime_sec; long mtime_nsec;
  int64_t ctime_sec; long ctime_nsec; int64_t birthtime_sec; long birthtime_nsec;
  int64_t size; int64_t blocks; int32_t blksize; uint32_t flags; uint32_t gen; int32_t lspare; int64_t qspare[2];
} __wlo_stat_t;
typedef struct {
  uint64_t ino; uint64_t seekoff; uint16_t reclen; uint16_t namlen; uint8_t type; char name[1024];
} __wlo_dirent_t;
int __wlo_c_mkdir(const char *path, uint16_t mode) __asm__("mkdir");
char ***__wlo_c_environ(void) __asm__("_NSGetEnviron");
]])
elseif __wlo_ffi.arch == "x64" then
  __wlo_ffi.cdef([[
typedef struct {
  uint64_t dev; uint64_t ino; uint64_t nlink; uint32_t mode; uint32_t uid; uint32_t gid; int32_t pad;
  uint64_t rdev; int64_t size; int64_t blksize; int64_t blocks;
  int64_t atime_sec; long atime_nsec; int64_t mtime_sec; long mtime_nsec; int64_t ctime_sec; long ctime_nsec;
  long reserved[3];
} __wlo_stat_t;
]])
else
  __wlo_ffi.cdef([[
typedef struct {
  uint64_t dev; uint64_t ino; uint32_t mode; uint32_t nlink; uint32_t uid; uint32_t gid;
  uint64_t rdev; uint64_t pad; int64_t size; int32_t blksize; int32_t pad2; int64_t blocks;
  int64_t atime_sec; long atime_nsec; int64_t mtime_sec; long mtime_nsec; int64_t ctime_sec; long ctime_nsec;
  uint32_t unused[2];
} __wlo_stat_t;
]])
end
if not __wlo_OSX then
  __wlo_ffi.cdef([[
typedef struct { uint64_t ino; int64_t off; uint16_t reclen; uint8_t type; char name[256]; } __wlo_dirent_t;
int __wlo_c_mkdir(const char *path, uint32_t mode) __asm__("mkdir");
extern char **environ;
]])
end
local __wlo_host_cdef = [[
typedef struct { int64_t sec; long nsec; } __wlo_timespec_t;
int __wlo_c_stat(const char *path, __wlo_stat_t *buf) __asm__("stat%s");
int __wlo_c_lstat(const char *path, __wlo_stat_t *buf) __asm__("lstat%s");
void *__wlo_c_opendir(const char *path) __asm__("opendir%s");
__wlo_dirent_t *__wlo_c_readdir(void *dir) __asm__("readdir%s");
int __wlo_c_closedir(void *dir) __asm__("closedir");
int __wlo_c_unlink(const char *path) __asm__("unlink");
int __wlo_c_rmdir(const char *path) __asm__("rmdir");
int __wlo_c_rename(const char *source, const char *destination) __asm__("rename");
char *__wlo_c_getcwd(char *buf, size_t size) __asm__("getcwd");
char *__wlo_c_strerror(int errnum) __asm__("strerror");
int __wlo_c_clock_gettime(int clock, __wlo_timespec_t *time) __asm__("clock_gettime");
int __wlo_c_nanosleep(const __wlo_timespec_t *request, __wlo_timespec_t *remaining) __asm__("nanosleep");
typedef struct { int fd; short events; short revents; } __wlo_pollfd_t;
typedef struct { uint64_t data[64]; } __wlo_spawn_buffer_t;
int __wlo_c_pipe(int fds[2]) __asm__("pipe");
int __wlo_c_fcntl(int fd, int command, ...) __asm__("fcntl");
long __wlo_c_read(int fd, void *buffer, size_t size) __asm__("read");
long __wlo_c_write(int fd, const void *buffer, size_t size) __asm__("write");
int __wlo_c_close(int fd) __asm__("close");
int __wlo_c_poll(__wlo_pollfd_t *fds, unsigned long count, int timeout) __asm__("poll");
int __wlo_c_waitpid(int pid, int *status, int options) __asm__("waitpid");
int __wlo_c_kill(int pid, int signal) __asm__("kill");
int __wlo_c_access(const char *path, int mode) __asm__("access");
int __wlo_c_fileno(void *file) __asm__("fileno");
int64_t __wlo_c_lseek(int fd, int64_t offset, int whence) __asm__("lseek");
long __wlo_c_ftell(void *file) __asm__("ftell");
int __wlo_c_spawn(int *pid, const char *path, void *actions, void *attributes,
  const char **argv, const char **envp) __asm__("posix_spawn");
int __wlo_c_actions_init(void *actions) __asm__("posix_spawn_file_actions_init");
int __wlo_c_actions_destroy(void *actions) __asm__("posix_spawn_file_actions_destroy");
int __wlo_c_actions_dup2(void *actions, int fd, int target) __asm__("posix_spawn_file_actions_adddup2");
int __wlo_c_actions_chdir(void *actions, const char *path) __asm__("posix_spawn_file_actions_addchdir_np");
int __wlo_c_attributes_init(void *attributes) __asm__("posix_spawnattr_init");
int __wlo_c_attributes_destroy(void *attributes) __asm__("posix_spawnattr_destroy");
int __wlo_c_attributes_flags(void *attributes, short flags) __asm__("posix_spawnattr_setflags");
int __wlo_c_attributes_sigdefault(void *attributes, const void *signals) __asm__("posix_spawnattr_setsigdefault");
int __wlo_c_sigemptyset(void *signals) __asm__("sigemptyset");
int __wlo_c_sigaddset(void *signals, int signal) __asm__("sigaddset");
]]
__wlo_ffi.cdef((__wlo_host_cdef:gsub("%%s", __wlo_INODE64)))

local __wlo_C = __wlo_ffi.C
local __wlo_ENOENT, __wlo_ENOTDIR, __wlo_EEXIST, __wlo_EINTR, __wlo_EPIPE = 2, 20, 17, 4, 32
local __wlo_EAGAIN = __wlo_OSX and 35 or 11
local __wlo_O_NONBLOCK = __wlo_OSX and 0x4 or 0x800
local __wlo_CLOCK_MONOTONIC = __wlo_OSX and 6 or 1

-- Raises OSError for the failed host call that set errno.
local function __wlo_host_error(action, path, site)
  local reason = __wlo_ffi.string(__wlo_C.__wlo_c_strerror(__wlo_ffi.errno()))
  __wlo_fail("OSError", "cannot " .. action .. (path and " " .. path or "") .. ": " .. reason, site)
end

local function __wlo_check_path(path, site)
  if path:find("\0", 1, true) then
    __wlo_fail("ValueError", "path contains a NUL character", site)
  end
end

local function __wlo_check_text(text, site)
  if not __wlo_valid_utf8(text) then
    __wlo_fail("ValueError", "invalid UTF-8", site)
  end
  return text
end

function __wlo_join(a, b, site)
  if b:sub(1, 1) == "/" then
    return b
  elseif a == "" or a:sub(-1) == "/" then
    return a .. b
  end
  return a .. "/" .. b
end

function __wlo_basename(path, site)
  return path:match("[^/]*$")
end

-- A head of only slashes keeps them all, as in Python.
function __wlo_dirname(path, site)
  local head = path:match("^(.*/)") or ""
  if head:find("[^/]") then
    head = head:gsub("/+$", "")
  end
  return head
end

function __wlo_listdir(path, site)
  __wlo_check_path(path, site)
  local dir = __wlo_C.__wlo_c_opendir(path)
  if dir == nil then
    __wlo_host_error("list", path, site)
  end
  local names = {}
  while true do
    local entry = __wlo_C.__wlo_c_readdir(dir)
    if entry == nil then
      break
    end
    local name = __wlo_ffi.string(entry.name)
    if name ~= "." and name ~= ".." then
      names[#names + 1] = name
    end
  end
  __wlo_C.__wlo_c_closedir(dir)
  table.sort(names)
  for _, name in ipairs(names) do
    __wlo_check_text(name, site)
  end
  return __wlo_list(names, #names)
end

local __wlo_KINDS = { [0x8000] = "file", [0x4000] = "directory", [0xA000] = "symlink" }

function __wlo_stat(path, follow_symlinks, site)
  __wlo_check_path(path, site)
  local buf = __wlo_ffi.new("__wlo_stat_t")
  local status = follow_symlinks and __wlo_C.__wlo_c_stat(path, buf) or __wlo_C.__wlo_c_lstat(path, buf)
  if status ~= 0 then
    __wlo_host_error("stat", path, site)
  end
  if buf.size > __wlo_MAX_INT then
    __wlo_fail("OverflowError", "file size out of range", site)
  end
  return {
    __wlo_record = "fs.Stat",
    kind = __wlo_KINDS[bit.band(buf.mode, 0xF000)] or "other",
    size = tonumber(buf.size),
    modified = tonumber(buf.mtime_sec) + tonumber(buf.mtime_nsec) / 1e9,
  }
end

-- Only a missing path or a non-directory component means false.
function __wlo_exists(path, site)
  __wlo_check_path(path, site)
  if __wlo_C.__wlo_c_stat(path, __wlo_ffi.new("__wlo_stat_t")) == 0 then
    return true
  end
  local err = __wlo_ffi.errno()
  if err == __wlo_ENOENT or err == __wlo_ENOTDIR then
    return false
  end
  __wlo_host_error("stat", path, site)
end

local function __wlo_has_kind(path, kind)
  local buf = __wlo_ffi.new("__wlo_stat_t")
  return __wlo_C.__wlo_c_stat(path, buf) == 0 and bit.band(buf.mode, 0xF000) == kind
end

local function __wlo_is_directory(path)
  return __wlo_has_kind(path, 0x4000)
end

local function __wlo_is_regular(path)
  return __wlo_has_kind(path, 0x8000)
end

function __wlo_mkdir(path, parents, exist_ok, site)
  __wlo_check_path(path, site)
  path = path:gsub("(.)/+$", "%1")
  if __wlo_C.__wlo_c_mkdir(path, 511) == 0 then
    return
  end
  local err = __wlo_ffi.errno()
  if err == __wlo_ENOENT and parents then
    local parent = __wlo_dirname(path)
    if parent ~= "" and parent ~= path then
      __wlo_mkdir(parent, true, true, site)
      if __wlo_C.__wlo_c_mkdir(path, 511) == 0 then
        return
      end
      err = __wlo_ffi.errno()
    end
  end
  if err == __wlo_EEXIST and exist_ok and __wlo_is_directory(path) then
    return
  end
  __wlo_ffi.errno(err)
  __wlo_host_error("create directory", path, site)
end

function __wlo_remove(path, site)
  __wlo_check_path(path, site)
  if __wlo_C.__wlo_c_unlink(path) ~= 0 then
    __wlo_host_error("remove", path, site)
  end
end

function __wlo_rmdir(path, site)
  __wlo_check_path(path, site)
  if __wlo_C.__wlo_c_rmdir(path) ~= 0 then
    __wlo_host_error("remove directory", path, site)
  end
end

function __wlo_rename(source, destination, site)
  __wlo_check_path(source, site)
  __wlo_check_path(destination, site)
  if __wlo_C.__wlo_c_rename(source, destination) ~= 0 then
    __wlo_host_error("rename " .. source .. " to", destination, site)
  end
end

local function __wlo_check_name(name, site)
  if name == "" or name:find("[=%z]") then
    __wlo_fail("ValueError", "invalid environment variable name", site)
  end
end

function __wlo_getenv(name, site)
  __wlo_check_name(name, site)
  local value = os.getenv(name)
  return value and __wlo_check_text(value, site)
end

function __wlo_environ(site)
  local environ = __wlo_OSX and __wlo_C.__wlo_c_environ()[0] or __wlo_C.environ
  local names, values = {}, {}
  local i = 0
  while environ[i] ~= nil do
    local name, value = __wlo_ffi.string(environ[i]):match("^([^=]*)=(.*)$")
    if name and not values[name] then
      names[#names + 1] = name
      values[name] = __wlo_check_text(value, site)
      __wlo_check_text(name, site)
    end
    i = i + 1
  end
  table.sort(names)
  local entries = {}
  for _, name in ipairs(names) do
    entries[#entries + 1] = name
    entries[#entries + 1] = values[name]
  end
  return __wlo_dict(entries, #names)
end

function __wlo_getcwd(site)
  local buf = __wlo_ffi.new("char[?]", 4096)
  if __wlo_C.__wlo_c_getcwd(buf, 4096) == nil then
    __wlo_host_error("get the working directory", nil, site)
  end
  return __wlo_check_text(__wlo_ffi.string(buf), site)
end

local function __wlo_clock(clock)
  local now = __wlo_ffi.new("__wlo_timespec_t")
  __wlo_C.__wlo_c_clock_gettime(clock, now)
  return tonumber(now.sec) + tonumber(now.nsec) / 1e9
end

function __wlo_time(site)
  return __wlo_clock(0)
end

function __wlo_monotonic(site)
  return __wlo_clock(__wlo_CLOCK_MONOTONIC)
end

function __wlo_sleep(seconds, site)
  if not (seconds >= 0 and seconds < math.huge) then
    __wlo_fail("ValueError", "sleep length must be finite and nonnegative", site)
  end
  local request = __wlo_ffi.new("__wlo_timespec_t")
  local remaining = __wlo_ffi.new("__wlo_timespec_t")
  request.sec = math.floor(seconds)
  request.nsec = math.floor((seconds - math.floor(seconds)) * 1e9)
  while __wlo_C.__wlo_c_nanosleep(request, remaining) ~= 0 and __wlo_ffi.errno() == __wlo_EINTR do
    request.sec, request.nsec = remaining.sec, remaining.nsec
  end
end

-- Seconds of 0001-01-01T00:00:00Z and 9999-12-31T23:59:59Z.
local __wlo_UTC_MIN, __wlo_UTC_MAX = -62135596800, 253402300799

-- Converts days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
function __wlo_utc(timestamp, site)
  local seconds = math.floor(timestamp)
  if not (seconds >= __wlo_UTC_MIN and seconds <= __wlo_UTC_MAX) then
    __wlo_fail("ValueError", "timestamp out of range", site)
  end
  local days = math.floor(seconds / 86400)
  local rest = seconds - days * 86400
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local day = doy - math.floor((153 * mp + 2) / 5) + 1
  local month = mp < 10 and mp + 3 or mp - 9
  local year = yoe + era * 400 + (month <= 2 and 1 or 0)
  return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day,
    math.floor(rest / 3600), math.floor(rest % 3600 / 60), rest % 60)
end

-- Processes. A child gets the descriptors named in `redirects` and inherits
-- the others; Willow's own pipe ends are close-on-exec, so only their copies
-- on 0, 1, and 2 reach it.

local __wlo_SIGPIPE, __wlo_SIGTERM, __wlo_SIGKILL = 13, 15, 9
local __wlo_POSIX_SPAWN_SETSIGDEF = 4
local __wlo_F_DUPFD_CLOEXEC = __wlo_OSX and 67 or 1030

local function __wlo_check_timeout(timeout, site)
  if timeout ~= nil and not (timeout > 0 and timeout < math.huge) then
    __wlo_fail("ValueError", "timeout must be finite and positive", site)
  end
end

-- The descriptor of a Lua file; LuaJIT converts a file to its FILE pointer.
local function __wlo_fd(file)
  return __wlo_C.__wlo_c_fileno(__wlo_ffi.cast("void *", file))
end

local function __wlo_fcntl(fd, command, value)
  return __wlo_C.__wlo_c_fcntl(fd, command, __wlo_ffi.new("int", value))
end

-- A pipe whose ends are closed in children: { read, write }.
local function __wlo_pipe(site)
  local fds = __wlo_ffi.new("int[2]")
  if __wlo_C.__wlo_c_pipe(fds) ~= 0 then
    __wlo_host_error("create a pipe", nil, site)
  end
  for i = 0, 1 do
    __wlo_fcntl(fds[i], 2, 1) -- F_SETFD, FD_CLOEXEC
  end
  return { fds[0], fds[1] }
end

local function __wlo_nonblocking(fd)
  __wlo_fcntl(fd, 4, bit.bor(__wlo_C.__wlo_c_fcntl(fd, 3), __wlo_O_NONBLOCK)) -- F_SETFL, F_GETFL
end

-- The exit code, or the negative signal number, from a waitpid status.
local function __wlo_exit_code(status)
  local signal = bit.band(status, 0x7f)
  if signal == 0 then
    return bit.band(bit.rshift(status, 8), 0xff)
  end
  return -signal
end

-- The child's exit code, or nil when `block` is false and it is running.
local function __wlo_reap(pid, block)
  local status = __wlo_ffi.new("int[1]")
  while true do
    local result = __wlo_C.__wlo_c_waitpid(pid, status, block and 0 or 1) -- WNOHANG
    if result == pid then
      return __wlo_exit_code(status[0])
    elseif result == 0 or __wlo_ffi.errno() ~= __wlo_EINTR then
      return nil
    end
  end
end

-- The full path of executable `name`, searched in `path` unless it has a slash.
local function __wlo_find_program(name, path)
  if name:find("/", 1, true) then
    return name
  end
  for dir in (path .. ":"):gmatch("([^:]*):") do
    local candidate = __wlo_join(dir == "" and "." or dir, name)
    if __wlo_C.__wlo_c_access(candidate, 1) == 0 and __wlo_is_regular(candidate) then
      return candidate
    end
  end
end

-- The environment `env` (nil to inherit) as `name=value` strings, and its PATH.
local function __wlo_child_environment(env, site)
  if not env then
    local environ = __wlo_OSX and __wlo_C.__wlo_c_environ()[0] or __wlo_C.environ
    return environ, os.getenv("PATH")
  end
  local strings = {}
  for _, name in ipairs(env.keys) do
    local value = env.values[name]
    __wlo_check_name(name, site)
    if value:find("\0", 1, true) then
      __wlo_fail("ValueError", "environment value contains a NUL character", site)
    end
    strings[#strings + 1] = name .. "=" .. value
  end
  return strings, env.values.PATH
end

-- A C array of `strings` ending in NULL, valid while `strings` is reachable.
local function __wlo_c_strings(strings)
  local array = __wlo_ffi.new("const char *[?]", #strings + 1)
  for i, text in ipairs(strings) do
    array[i - 1] = text
  end
  return array
end

local function __wlo_flush_file(file, path, site)
  local ok, err = file:flush()
  if not ok then
    __wlo_fail("OSError", "cannot write " .. path .. ": " .. tostring(err), site)
  end
end

-- Starts `args` and returns its pid. `redirects` maps 0, 1, and 2 to the
-- descriptors the child gets for them.
local function __wlo_launch(args, cwd, env, redirects, site)
  if args.n == 0 or args[1] == "" then
    __wlo_fail("ValueError", "args must contain a nonempty executable name", site)
  end
  local list = {}
  for i = 1, args.n do
    if args[i]:find("\0", 1, true) then
      __wlo_fail("ValueError", "argument contains a NUL character", site)
    end
    list[i] = args[i]
  end
  if cwd then
    __wlo_check_path(cwd, site)
  end
  local environment, search_path = __wlo_child_environment(env, site)
  local program = __wlo_find_program(list[1], search_path or "/usr/bin:/bin")
  if not program then
    __wlo_fail("OSError", "cannot run " .. list[1] .. ": No such file or directory", site)
  end
  __wlo_flush_file(io.stdout, "<stdout>", site)
  __wlo_flush_file(io.stderr, "<stderr>", site)

  local actions = __wlo_ffi.new("__wlo_spawn_buffer_t[1]")
  local attributes = __wlo_ffi.new("__wlo_spawn_buffer_t[1]")
  local signals = __wlo_ffi.new("uint64_t[16]")
  __wlo_C.__wlo_c_actions_init(actions)
  __wlo_C.__wlo_c_attributes_init(attributes)
  -- A source among 0, 1, and 2 is first copied above them, so that an earlier
  -- dup2 cannot replace it, as when stdout and stderr are swapped.
  local copies = {}
  for target = 0, 2 do
    local source = redirects[target]
    if source then
      if source < 3 and source ~= target then
        source = __wlo_fcntl(source, __wlo_F_DUPFD_CLOEXEC, 3)
        copies[#copies + 1] = source
      end
      __wlo_C.__wlo_c_actions_dup2(actions, source, target)
    end
  end
  if cwd then
    __wlo_C.__wlo_c_actions_chdir(actions, cwd)
  end
  -- Willow ignores SIGPIPE; children get the default action back.
  __wlo_C.__wlo_c_sigemptyset(signals)
  __wlo_C.__wlo_c_sigaddset(signals, __wlo_SIGPIPE)
  __wlo_C.__wlo_c_attributes_sigdefault(attributes, signals)
  __wlo_C.__wlo_c_attributes_flags(attributes, __wlo_POSIX_SPAWN_SETSIGDEF)

  -- The Lua strings in `list` and `environment` keep the C strings alive.
  local argv = __wlo_c_strings(list)
  local envp = type(environment) == "table" and __wlo_c_strings(environment)
    or __wlo_ffi.cast("const char **", environment)
  local pid = __wlo_ffi.new("int[1]")
  local err = __wlo_C.__wlo_c_spawn(pid, program, actions, attributes, argv, envp)
  for _, fd in ipairs(copies) do
    __wlo_C.__wlo_c_close(fd)
  end
  __wlo_C.__wlo_c_actions_destroy(actions)
  __wlo_C.__wlo_c_attributes_destroy(attributes)
  if err ~= 0 then
    __wlo_ffi.errno(err)
    __wlo_host_error("run", list[1], site)
  end
  return pid[0]
end

local function __wlo_close_fd(fd)
  if fd then
    __wlo_C.__wlo_c_close(fd)
  end
end

-- Reads what `fd` holds now into `parts`; returns false at end of file.
local function __wlo_drain(fd, parts, buffer)
  while true do
    local count = tonumber(__wlo_C.__wlo_c_read(fd, buffer, 65536))
    if count > 0 then
      parts[#parts + 1] = __wlo_ffi.string(buffer, count)
    elseif count == 0 then
      return false
    elseif __wlo_ffi.errno() ~= __wlo_EINTR then
      return __wlo_ffi.errno() == __wlo_EAGAIN
    end
  end
end

function __wlo_process_run(args, input, capture_output, cwd, env, timeout, site)
  __wlo_check_timeout(timeout, site)
  local redirects, stdin, stdout, stderr = {}, nil, nil, nil
  if input then
    stdin = __wlo_pipe(site)
    redirects[0] = stdin[1]
  end
  if capture_output then
    stdout, stderr = __wlo_pipe(site), __wlo_pipe(site)
    redirects[1], redirects[2] = stdout[2], stderr[2]
  end
  local ok, pid = pcall(__wlo_launch, args, cwd, env, redirects, site)
  for _, fd in pairs(redirects) do
    __wlo_C.__wlo_c_close(fd)
  end
  local input_fd = stdin and stdin[2]
  local readers = {}
  if capture_output then
    readers[stdout[1]], readers[stderr[1]] = {}, {}
  end
  if not ok then
    __wlo_close_fd(input_fd)
    for fd in pairs(readers) do
      __wlo_C.__wlo_c_close(fd)
    end
    error(pid, 0)
  end

  local octets, offset = input and input.__wlo_octets, 0
  if input_fd then
    __wlo_nonblocking(input_fd)
  end
  for fd in pairs(readers) do
    __wlo_nonblocking(fd)
  end
  local open = {}
  for fd in pairs(readers) do
    open[fd] = true
  end
  local buffer = __wlo_ffi.new("char[65536]")
  local deadline = timeout and __wlo_monotonic() + timeout
  local code
  while code == nil do
    if input_fd and offset >= #octets then
      __wlo_C.__wlo_c_close(input_fd)
      input_fd = nil
    end
    local fds, count = __wlo_ffi.new("__wlo_pollfd_t[3]"), 0
    local function watch(fd, events)
      fds[count].fd = fd
      fds[count].events = events
      count = count + 1
    end
    if input_fd then
      watch(input_fd, 4) -- POLLOUT
    end
    for fd in pairs(open) do
      watch(fd, 1) -- POLLIN
    end
    -- Without pipes to watch, only the child's exit or the deadline matters.
    local wait = count > 0 and 50 or 10
    if deadline then
      wait = math.max(0, math.min(wait, math.ceil((deadline - __wlo_monotonic()) * 1000)))
    end
    if count > 0 then
      __wlo_C.__wlo_c_poll(fds, count, wait)
    elseif not deadline then
      code = __wlo_reap(pid, true)
    else
      __wlo_sleep(wait / 1000)
    end
    for i = 0, count - 1 do
      local fd, revents = fds[i].fd, fds[i].revents
      if fd == input_fd and revents ~= 0 then
        local rest = octets:sub(offset + 1, offset + 65536)
        local written = tonumber(__wlo_C.__wlo_c_write(fd, rest, #rest))
        if written > 0 then
          offset = offset + written
        elseif __wlo_ffi.errno() ~= __wlo_EAGAIN and __wlo_ffi.errno() ~= __wlo_EINTR then
          -- The child closed its input, so the rest is dropped.
          offset = #octets
        end
      elseif open[fd] and revents ~= 0 and not __wlo_drain(fd, readers[fd], buffer) then
        open[fd] = nil
      end
    end
    code = code or __wlo_reap(pid, false)
    if code == nil and deadline and __wlo_monotonic() >= deadline then
      __wlo_C.__wlo_c_kill(pid, __wlo_SIGKILL)
      __wlo_reap(pid, true)
      __wlo_close_fd(input_fd)
      for fd in pairs(readers) do
        __wlo_C.__wlo_c_close(fd)
      end
      __wlo_fail("TimeoutError", "command timed out after " .. __wlo_format_float(timeout) .. " seconds", site)
    end
  end
  -- The child has exited; take what the pipes hold without waiting for any
  -- descendant that inherited them.
  __wlo_close_fd(input_fd)
  local captured = {}
  for fd, parts in pairs(readers) do
    if open[fd] then
      __wlo_drain(fd, parts, buffer)
    end
    __wlo_C.__wlo_c_close(fd)
    captured[fd] = { __wlo_octets = table.concat(parts) }
  end
  return {
    __wlo_record = "subprocess.Result",
    returncode = code,
    stdout = capture_output and captured[stdout[1]] or nil,
    stderr = capture_output and captured[stderr[1]] or nil,
  }
end

-- The descriptor of `handle` for the child's `name` stream, after checking it.
local function __wlo_child_stream(handle, name, reading, site)
  if handle.closed then
    __wlo_fail("ValueError", "I/O operation on closed file", site)
  elseif reading ~= (handle.mode == "r") then
    __wlo_fail("ValueError", name .. " must be open for " .. (reading and "reading" or "writing"), site)
  end
  local file = handle.file
  if reading and __wlo_read_files[file] then
    -- A seekable file's buffered input shows as a gap between its stdio and
    -- descriptor positions; otherwise any earlier read may have buffered some.
    -- ftell only reports the position, where Lua's seek would drop the buffer.
    local position = tonumber(__wlo_C.__wlo_c_ftell(__wlo_ffi.cast("void *", file)))
    if position < 0 or position ~= tonumber(__wlo_C.__wlo_c_lseek(__wlo_fd(file), 0, 1)) then
      __wlo_fail("ValueError", "stdin has buffered input", site)
    end
  elseif not reading then
    __wlo_flush_file(file, handle.path, site)
  end
  return __wlo_fd(file)
end

function __wlo_process_spawn(args, cwd, env, stdin, stdout, stderr, site)
  local redirects = {}
  redirects[0] = stdin and __wlo_child_stream(stdin, "stdin", true, site)
  redirects[1] = stdout and __wlo_child_stream(stdout, "stdout", false, site)
  redirects[2] = stderr and __wlo_child_stream(stderr, "stderr", false, site)
  return { __wlo_record = "subprocess.Process", pid = __wlo_launch(args, cwd, env, redirects, site) }
end

function __wlo_process_poll(process, site)
  if process.code == nil then
    process.code = __wlo_reap(process.pid, false)
  end
  return process.code
end

function __wlo_process_wait(process, timeout, site)
  __wlo_check_timeout(timeout, site)
  if process.code == nil and not timeout then
    process.code = __wlo_reap(process.pid, true)
  end
  local deadline = timeout and __wlo_monotonic() + timeout
  while process.code == nil do
    process.code = __wlo_reap(process.pid, false)
    if process.code == nil then
      if __wlo_monotonic() >= deadline then
        __wlo_fail("TimeoutError", "process did not exit within " .. __wlo_format_float(timeout) .. " seconds", site)
      end
      __wlo_sleep(math.min(0.01, math.max(0, deadline - __wlo_monotonic())))
    end
  end
  return process.code
end

function __wlo_process_terminate(process, site)
  if process.code == nil then
    __wlo_C.__wlo_c_kill(process.pid, __wlo_SIGTERM)
  end
end

function __wlo_process_kill(process, site)
  if process.code == nil then
    __wlo_C.__wlo_c_kill(process.pid, __wlo_SIGKILL)
  end
end

-- Terminals.

__wlo_ffi.cdef([[int __wlo_c_isatty(int fd) __asm__("isatty");]])

function __wlo_isatty(handle, site)
  if handle.closed then
    __wlo_fail("ValueError", "I/O operation on closed file", site)
  end
  return __wlo_C.__wlo_c_isatty(__wlo_fd(handle.file)) == 1
end

local function __wlo_capable(fd)
  return __wlo_C.__wlo_c_isatty(fd) == 1 and os.getenv("TERM") ~= "dumb"
end

function __wlo_color_enabled(handle, site)
  return __wlo_isatty(handle, site) and os.getenv("TERM") ~= "dumb" and os.getenv("NO_COLOR") == nil
end

local __wlo_COLORS = {
  default = false, black = 30, red = 31, green = 32, yellow = 33, blue = 34, magenta = 35, cyan = 36, white = 37,
}

function __wlo_style(text, color, bold, enabled, site)
  local code = __wlo_COLORS[color]
  if code == nil then
    __wlo_fail("ValueError", "unknown color '" .. color .. "'", site)
  end
  local codes = {}
  if bold then
    codes[#codes + 1] = "1"
  end
  if code then
    codes[#codes + 1] = tostring(code)
  end
  if not enabled or #codes == 0 then
    return text
  end
  return "\27[" .. table.concat(codes, ";") .. "m" .. text .. "\27[0m"
end

local function __wlo_write_stderr(text, site)
  local ok, err = io.stderr:write(text)
  if ok then
    ok, err = io.stderr:flush()
  end
  if not ok then
    __wlo_host_fail("cannot write output: " .. tostring(err), site)
  end
end

function __wlo_progress(message, site)
  if message:find("[\r\n]") then
    __wlo_fail("ValueError", "progress message cannot contain a line break", site)
  end
  if __wlo_capable(2) then
    __wlo_write_stderr("\r\27[K" .. message, site)
  end
end

function __wlo_finish_progress(message, site)
  local text = __wlo_capable(2) and "\r\27[K" or ""
  if message ~= "" then
    text = text .. message .. "\n"
  end
  __wlo_write_stderr(text, site)
end
