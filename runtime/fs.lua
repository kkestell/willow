-- Filesystem helpers beyond host.lua's, inlined after runtime/core.lua into
-- programs that call them. They use host.lua's C declarations and exports
-- through the C namespace and `__wlo_runtime`. The helpers are the functions
-- declared without `local`.

__wlo_ffi.cdef([[
char *__wlo_c_realpath(const char *path, char *resolved) __asm__("realpath");
int __wlo_c_mkstemp(char *template) __asm__("mkstemp");
char *__wlo_c_mkdtemp(char *template) __asm__("mkdtemp");
int __wlo_c_fnmatch(const char *pattern, const char *name, int flags) __asm__("fnmatch");
]])

local __wlo_C = __wlo_ffi.C
local __wlo_FNM_NOESCAPE = __wlo_ffi.os == "OSX" and 1 or 2
local __wlo_FNM_PERIOD = 4
local __wlo_COPY_CHUNK = 65536

local function __wlo_fs_reason()
  return __wlo_ffi.string(__wlo_C.__wlo_c_strerror(__wlo_ffi.errno()))
end

local function __wlo_fs_error(action, path, site)
  __wlo_fail("OSError", "cannot " .. action .. " " .. path .. ": " .. __wlo_fs_reason(), site)
end

function __wlo_read_bytes(path, site)
  __wlo_check_path(path, site)
  local file, err = io.open(path, "rb")
  if not file then
    __wlo_fail("OSError", "cannot read " .. path .. ": " .. __wlo_open_reason(err, path), site)
  end
  local octets
  octets, err = file:read("*a")
  file:close()
  if not octets then
    __wlo_fail("OSError", "cannot read " .. path .. ": " .. tostring(err), site)
  end
  return { __wlo_octets = octets }
end

function __wlo_write_bytes(path, data, site)
  __wlo_write_file(path, data.__wlo_octets, site)
end

local function __wlo_same_file(a, b)
  local x, y = __wlo_ffi.new("__wlo_stat_t"), __wlo_ffi.new("__wlo_stat_t")
  return __wlo_C.__wlo_c_stat(a, x) == 0 and __wlo_C.__wlo_c_stat(b, y) == 0 and x.dev == y.dev and x.ino == y.ino
end

-- The destination is opened after the first read, so an unreadable source
-- leaves it untouched. Both files are closed before any failure is raised.
function __wlo_copy_file(source, destination, site)
  __wlo_check_path(source, site)
  __wlo_check_path(destination, site)
  local input, err = io.open(source, "rb")
  if not input then
    __wlo_fail("OSError", "cannot read " .. source .. ": " .. __wlo_open_reason(err, source), site)
  end
  local output, failure
  while true do
    local chunk
    chunk, err = input:read(__wlo_COPY_CHUNK)
    if err then
      failure = "cannot read " .. source .. ": " .. tostring(err)
      break
    end
    if not output then
      if __wlo_same_file(source, destination) then
        failure = "cannot copy " .. source .. " to " .. destination .. ": they are the same file"
        break
      end
      output, err = io.open(destination, "wb")
      if not output then
        failure = "cannot write " .. destination .. ": " .. __wlo_open_reason(err, destination)
        break
      end
    end
    if not chunk then
      break
    end
    local ok
    ok, err = output:write(chunk)
    if not ok then
      failure = "cannot write " .. destination .. ": " .. tostring(err)
      break
    end
  end
  input:close()
  if output then
    local closed
    closed, err = output:close()
    if not closed and not failure then
      failure = "cannot write " .. destination .. ": " .. tostring(err)
    end
  end
  if failure then
    __wlo_fail("OSError", failure, site)
  end
end

-- As in Python's posixpath.normpath, exactly two leading slashes are kept.
function __wlo_normpath(path, site)
  if path == "" then
    return "."
  end
  local slashes = path:match("^/*")
  slashes = #slashes == 2 and "//" or slashes ~= "" and "/" or ""
  local parts, n = {}, 0
  for part in path:gmatch("[^/]+") do
    if part ~= "." then
      if part ~= ".." or (slashes == "" and n == 0) or (n > 0 and parts[n] == "..") then
        n = n + 1
        parts[n] = part
      elseif n > 0 then
        parts[n] = nil
        n = n - 1
      end
    end
  end
  local result = slashes .. table.concat(parts, "/")
  return result == "" and "." or result
end

function __wlo_abspath(path, site)
  if path:sub(1, 1) ~= "/" then
    path = __wlo_runtime.join(__wlo_runtime.getcwd(site), path)
  end
  return __wlo_normpath(path, site)
end

function __wlo_realpath(path, site)
  __wlo_check_path(path, site)
  local buf = __wlo_ffi.new("char[4096]")
  if __wlo_C.__wlo_c_realpath(path, buf) == nil then
    __wlo_fs_error("resolve", path, site)
  end
  return __wlo_check_text(__wlo_ffi.string(buf), site)
end

-- The names in a directory in readdir order, or nil if it cannot be read.
local function __wlo_scan(path)
  local dir = __wlo_C.__wlo_c_opendir(path)
  if dir == nil then
    return nil
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
  return names
end

local function __wlo_exists_entry(path)
  return __wlo_C.__wlo_c_lstat(path, __wlo_ffi.new("__wlo_stat_t")) == 0
end

-- Whether `path` is a directory, following symlinks.
local function __wlo_is_dir(path)
  local buf = __wlo_ffi.new("__wlo_stat_t")
  return __wlo_C.__wlo_c_stat(path, buf) == 0 and bit.band(buf.mode, 0xF000) == 0x4000
end

-- The paths matching `pattern`, in no order. Like Python's glob, a directory
-- that cannot be read has no matches, and a name starting with `.` is matched
-- only by a pattern component that starts with `.`.
local function __wlo_glob_paths(pattern)
  local head, tail = __wlo_runtime.dirname(pattern), __wlo_runtime.basename(pattern)
  local heads = { head }
  if head:find("[*?[]") then
    heads = __wlo_glob_paths(head)
  end
  local paths = {}
  for _, directory in ipairs(heads) do
    if tail == "" then
      if __wlo_is_dir(directory) then
        paths[#paths + 1] = __wlo_runtime.join(directory, "")
      end
    elseif tail:find("[*?[]") then
      for _, name in ipairs(__wlo_scan(directory == "" and "." or directory) or {}) do
        if __wlo_C.__wlo_c_fnmatch(tail, name, __wlo_FNM_NOESCAPE + __wlo_FNM_PERIOD) == 0 then
          paths[#paths + 1] = __wlo_runtime.join(directory, name)
        end
      end
    else
      local path = __wlo_runtime.join(directory, tail)
      if __wlo_exists_entry(path) then
        paths[#paths + 1] = path
      end
    end
  end
  return paths
end

function __wlo_glob(pattern, site)
  __wlo_check_path(pattern, site)
  local paths = __wlo_glob_paths(pattern)
  table.sort(paths)
  for _, path in ipairs(paths) do
    __wlo_check_text(path, site)
  end
  return __wlo_list(paths, #paths)
end

-- Entries that are not real directories, including symlinks to directories,
-- are listed as files and never entered. Each directory is read completely,
-- and its handle closed, before its tuple is returned.
function __wlo_walk(path, site)
  local pending = { path }
  return __wlo_iterator(function()
    local directory = table.remove(pending)
    if directory == nil then
      return
    end
    local names = __wlo_runtime.listdir(directory, site)
    local dirs, files, nd, nf = {}, {}, 0, 0
    for i = 1, names.n do
      local name = names[i]
      local buf = __wlo_ffi.new("__wlo_stat_t")
      local child = __wlo_runtime.join(directory, name)
      if __wlo_C.__wlo_c_lstat(child, buf) ~= 0 then
        __wlo_fs_error("stat", child, site)
      end
      if bit.band(buf.mode, 0xF000) == 0x4000 then
        nd = nd + 1
        dirs[nd] = name
      else
        nf = nf + 1
        files[nf] = name
      end
    end
    for i = nd, 1, -1 do
      pending[#pending + 1] = __wlo_runtime.join(directory, dirs[i])
    end
    return true, { __wlo_tuple = 3, directory, __wlo_list(dirs, nd), __wlo_list(files, nf) }
  end)
end

-- Creates the entry from `prefix` and six random characters in `directory`,
-- TMPDIR, or /tmp. `kind` is "file" or "directory".
local function __wlo_temp(kind, prefix, directory, site)
  if prefix:find("/", 1, true) or prefix:find("\0", 1, true) then
    __wlo_fail("ValueError", "prefix must be a single path component", site)
  end
  if directory == nil then
    directory = os.getenv("TMPDIR")
    if directory == nil or directory == "" then
      directory = "/tmp"
    end
  else
    __wlo_check_path(directory, site)
  end
  __wlo_check_text(directory, site)
  local text = __wlo_runtime.join(directory, prefix .. "XXXXXX")
  local template = __wlo_ffi.new("char[?]", #text + 1, text)
  if kind == "file" then
    local fd = __wlo_C.__wlo_c_mkstemp(template)
    if fd < 0 then
      __wlo_fs_error("create temporary file in", directory, site)
    end
    __wlo_C.__wlo_c_close(fd)
  elseif __wlo_C.__wlo_c_mkdtemp(template) == nil then
    __wlo_fs_error("create temporary directory in", directory, site)
  end
  return __wlo_ffi.string(template)
end

function __wlo_temp_file(prefix, directory, site)
  return __wlo_temp("file", prefix, directory, site)
end

function __wlo_temp_dir(prefix, directory, site)
  return __wlo_temp("directory", prefix, directory, site)
end
