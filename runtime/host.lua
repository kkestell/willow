-- Filesystem, environment, and clock helpers, inlined after runtime/core.lua
-- into programs that call them. The helpers are the functions declared without
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
]]
__wlo_ffi.cdef((__wlo_host_cdef:gsub("%%s", __wlo_INODE64)))

local __wlo_C = __wlo_ffi.C
local __wlo_ENOENT, __wlo_ENOTDIR, __wlo_EEXIST, __wlo_EINTR = 2, 20, 17, 4
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

local function __wlo_is_directory(path)
  local buf = __wlo_ffi.new("__wlo_stat_t")
  return __wlo_C.__wlo_c_stat(path, buf) == 0 and bit.band(buf.mode, 0xF000) == 0x4000
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
