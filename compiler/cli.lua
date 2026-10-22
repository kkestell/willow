-- Command-line entry point, run by the willow launcher on the bundled LuaJIT.

local root = arg[0]:match("^(.*)/compiler/[^/]*$") or "."
package.path = root .. "/?.lua"

local ffi = require("ffi")
local diag = require("compiler.diag")
local loader = require("compiler.loader")
local manifest = require("compiler.manifest")
local bind = require("compiler.bind")
local check = require("compiler.check")
local lower = require("compiler.lower")
local emit = require("compiler.emit")
local runner = require("compiler.runner")

ffi.cdef([[int setenv(const char *name, const char *value, int overwrite);]])
if ffi.os == "OSX" then
  ffi.cdef([[int chmod(const char *path, uint16_t mode);]])
else
  ffi.cdef([[int chmod(const char *path, uint32_t mode);]])
end

local USAGE = "usage: willow init\n       willow check [file]\n       willow run [file [args...] | -- args...]\n"
  .. "       willow compile [file] -o <output>\n       willow build [file] -o <output>\n"
  .. "       willow test [--check] [path]\n"
  .. "Without a file, the command uses willow.json in the current directory."

local function fail(message)
  io.stderr:write(message, "\n")
  os.exit(1)
end

local function usage_error(reason)
  fail("error: " .. reason .. "\n" .. USAGE)
end

-- `willow test [--check] [path]`, with the path defaulting to the current
-- directory.
local function parse_test_args(args)
  local check_only, path = false, nil
  for i = 2, #args do
    local argument = args[i]
    if argument == "--check" and not check_only then
      check_only = true
    elseif argument == "--check" then
      usage_error("--check given more than once")
    elseif argument:sub(1, 1) == "-" then
      usage_error("unknown option '" .. argument .. "'")
    elseif path then
      usage_error("unexpected argument '" .. argument .. "'")
    else
      path = argument
    end
  end
  return path, check_only
end

local function parse_args(args)
  local command = args[1]
  if not command then
    usage_error("missing command")
  elseif command ~= "check" and command ~= "run" and command ~= "compile" and command ~= "build" then
    usage_error("unknown command '" .. command .. "'")
  end
  local writes = command == "compile" or command == "build"
  local input, output
  local program_args = {}
  local i = 2
  while i <= #args do
    local argument = args[i]
    if input and command == "run" then
      -- Everything after the source path belongs to the program.
      program_args[#program_args + 1] = argument
      i = i + 1
    elseif argument == "--" and not input and command == "run" then
      -- `run -- args` runs the project entry with `args`.
      for j = i + 1, #args do
        program_args[#program_args + 1] = args[j]
      end
      break
    elseif argument == "-o" and writes then
      if output then
        usage_error("-o given more than once")
      end
      output = args[i + 1]
      if not output then
        usage_error("-o needs a path")
      end
      i = i + 2
    elseif argument:sub(1, 1) == "-" then
      usage_error("unknown option '" .. argument .. "'")
    elseif input then
      usage_error("unexpected argument '" .. argument .. "'")
    else
      input = argument
      i = i + 1
    end
  end
  if writes and not output then
    usage_error(command .. " needs -o <output>")
  end
  return command, input, output, program_args
end

-- True when both paths name the same existing file, following symlinks.
local function same_file(a, b)
  local id = loader.file_id(a)
  return id ~= nil and id == loader.file_id(b)
end

-- Writes through an exclusively created sibling and renames it into place, so
-- a failure leaves any existing output untouched. `mode` sets the permissions
-- when given.
local function write_output(output, text, mode)
  local temp = output .. ".tmp"
  local file, err = io.open(temp, "wbx")
  if not file then
    fail("error: cannot write " .. output .. ": " .. err)
  end
  local ok
  ok, err = file:write(text)
  if ok then
    ok, err = file:flush()
  end
  local closed, close_err = file:close()
  if ok and not closed then
    ok, err = closed, close_err
  end
  if ok and mode and ffi.C.chmod(temp, mode) ~= 0 then
    ok, err = false, "cannot set permissions"
  end
  if ok then
    ok, err = os.rename(temp, output)
  end
  if not ok then
    os.remove(temp)
    fail("error: cannot write " .. output .. ": " .. tostring(err))
  end
end

-- Checks the whole program and returns its modules and, for every command but
-- check, the generated Lua and its loaded chunk. A test entry is a test file.
local function translate(command, path, source, roots, test)
  local modules = loader.load(path, source, roots)
  bind.bind(modules, test)
  check.check(modules)
  if command ~= "check" then
    local text = emit.emit(lower.lower(modules))
    return modules, text, assert(load(text, "=" .. path))
  end
  return modules
end

-- The stub, then the Lua, an 8-byte little-endian length, and the magic the
-- stub looks for at the end of its own file.
local function executable(text)
  local stub = package.preload["willow.stub"] and require("willow.stub")
  if not stub then
    local stub_path = root .. "/runtime/stub"
    local stub_file, err = io.open(stub_path, "rb")
    if not stub_file then
      fail("error: " .. err)
    end
    stub = stub_file:read("*a")
    stub_file:close()
  end
  local length, bytes = #text, {}
  for i = 1, 8 do
    bytes[i] = string.char(length % 256)
    length = math.floor(length / 256)
  end
  return stub .. text .. table.concat(bytes) .. "WILLOWLU"
end

local function report(err)
  if diag.is(err) then
    return err
  end
  local message = "internal compiler error: " .. tostring(err)
  -- check.lua re-raises internal errors with the traceback of the fault.
  if message:find("\nstack traceback:\n", 1, true) then
    return message
  end
  return debug.traceback(message, 1)
end

-- Formats the error `translate` raised.
local function format_error(err)
  if not diag.is(err) then
    return err
  end
  local lines = {}
  for i, d in ipairs(err) do
    lines[i] = diag.format(d)
  end
  return table.concat(lines, "\n")
end

-- Module roots for the explicit file at `path`: its own directory first.
local function file_roots(path)
  return {
    primary = path:match("^(.*/)") or "",
    entry_name = (path:match("([^/]*)$"):gsub("%.wlo$", "")),
  }
end

-- Module roots for `project` whose entry module is named `entry_name`.
local function project_roots(project, entry_name)
  return { primary = project.source, dependencies = project.dependencies, entry_name = entry_name }
end

-- The project in the current directory, or nil; a broken manifest fails.
local function read_project()
  local project, err = manifest.read()
  if project == false then
    fail("error: " .. err)
  end
  return project
end

-- The test chunk and test names of the test file at `path`, or false and the
-- diagnostics. Imports use `project`'s roots when there is a project.
local function compile_test(path, project)
  local source, err = loader.read(path)
  if not source then
    return false, "error: " .. err
  end
  local roots = project and project_roots(project, file_roots(path).entry_name) or file_roots(path)
  local ok, modules, text = xpcall(translate, report, "test", path, source, roots, true)
  if not ok then
    return false, format_error(modules)
  end
  local names = {}
  for i, fn in ipairs(modules[1].tests) do
    names[i] = fn.name
  end
  return text, names
end

if package.preload["willow.stub"] and (arg[1] == "run" or arg[1] == "test") then
  if ffi.C.setenv("WILLOW", arg[0], 1) ~= 0 then
    fail("error: cannot set WILLOW")
  end
end

if arg[1] == "init" then
  if arg[2] then
    usage_error("unexpected argument '" .. arg[2] .. "'")
  end
  require("compiler.init").init()
  os.exit(0)
end

if arg[1] == "test" then
  local test_path, check_only = parse_test_args(arg)
  local project = read_project()
  local function compile(file)
    return compile_test(file, project)
  end
  local function write_program(path, text)
    write_output(path, executable(text), 493) -- 0755
  end
  os.exit(runner.test(write_program, test_path or project and project.tests or ".", check_only,
    compile, project ~= nil))
end

local command, path, output, program_args = parse_args(arg)
local roots
if path then
  roots = file_roots(path)
else
  local project = read_project()
  if not project then
    fail("error: no source file given and no willow.json in the current directory")
  end
  path, roots = project.entry, project_roots(project, project.entry_name)
end

local source, err = loader.read(path)
if not source then
  fail("error: " .. err)
end

if output and same_file(path, output) then
  fail("error: output " .. output .. " is the input file")
end

local ok, modules, text, chunk = xpcall(translate, report, command, path, source, roots)
if not ok then
  fail(format_error(modules))
end
if command == "run" then
  chunk(unpack(program_args))
elseif output then
  for i = 2, #modules do
    if same_file(modules[i].path, output) then
      fail("error: output " .. output .. " is the module file " .. modules[i].path)
    end
  end
  if command == "compile" then
    write_output(output, text)
  else
    write_output(output, executable(text), 493) -- 0755
  end
end
