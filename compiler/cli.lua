-- Command-line entry point, run by the willow launcher on the bundled LuaJIT.

local root = arg[0]:match("^(.*)/compiler/[^/]*$") or "."
package.path = root .. "/?.lua"

local ffi = require("ffi")
local diag = require("compiler.diag")
local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local lower = require("compiler.lower")
local emit = require("compiler.emit")

-- Only the device and inode are read; the padding covers the rest of any
-- platform's struct stat.
if ffi.os == "OSX" then
  ffi.cdef([[typedef struct { int32_t dev; uint16_t mode; uint16_t nlink; uint64_t ino; uint8_t rest[256]; } willow_stat;]])
else
  ffi.cdef([[typedef struct { uint64_t dev; uint64_t ino; uint8_t rest[256]; } willow_stat;]])
end
if ffi.os == "OSX" and ffi.arch == "x64" then
  ffi.cdef([[int stat(const char *path, willow_stat *buf) __asm__("stat$INODE64");]])
else
  ffi.cdef([[int stat(const char *path, willow_stat *buf);]])
end

local USAGE = "usage: willow check <file>\n       willow run <file>\n       willow build <file> -o <output>"

local function fail(message)
  io.stderr:write(message, "\n")
  os.exit(1)
end

local function usage_error(reason)
  fail("error: " .. reason .. "\n" .. USAGE)
end

local function parse_args(args)
  local command = args[1]
  if not command then
    usage_error("missing command")
  elseif command ~= "check" and command ~= "run" and command ~= "build" then
    usage_error("unknown command '" .. command .. "'")
  end
  local input, output
  local i = 2
  while i <= #args do
    local argument = args[i]
    if argument == "-o" and command == "build" then
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
  if not input then
    usage_error("missing input file")
  end
  if command == "build" and not output then
    usage_error("build needs -o <output>")
  end
  return command, input, output
end

-- True when both paths name the same existing file, following symlinks.
local function same_file(a, b)
  local stat_a, stat_b = ffi.new("willow_stat"), ffi.new("willow_stat")
  if ffi.C.stat(a, stat_a) ~= 0 or ffi.C.stat(b, stat_b) ~= 0 then
    return false
  end
  return stat_a.dev == stat_b.dev and stat_a.ino == stat_b.ino
end

-- Writes through an exclusively created sibling and renames it into place, so
-- a failure leaves any existing output untouched.
local function write_output(output, text)
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
  if ok then
    ok, err = os.rename(temp, output)
  end
  if not ok then
    os.remove(temp)
    fail("error: cannot write " .. output .. ": " .. tostring(err))
  end
end

-- Checks the whole program and, for run and build, returns the generated Lua
-- and its loaded chunk.
local function compile(command, path, source)
  local program = parser.parse(lexer.lex(source))
  bind.bind(program)
  check.check(program)
  if command ~= "check" then
    local text = emit.emit(lower.lower(program), path)
    return text, assert(load(text, "=" .. path))
  end
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

local command, path, output = parse_args(arg)

local file, err = io.open(path, "rb")
if not file then
  fail("error: " .. err)
end
local source, read_err = file:read("*a")
file:close()
if not source then
  fail("error: " .. path .. ": " .. read_err)
end

if output and same_file(path, output) then
  fail("error: output " .. output .. " is the input file")
end

local ok, text, chunk = xpcall(compile, report, command, path, source)
if not ok then
  if not diag.is(text) then
    fail(text)
  end
  local lines = {}
  for i, d in ipairs(text) do
    lines[i] = diag.format(path, d)
  end
  fail(table.concat(lines, "\n"))
end
if command == "run" then
  chunk()
elseif command == "build" then
  write_output(output, text)
end
