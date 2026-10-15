-- Command-line entry point, run by the willow launcher on the bundled LuaJIT.

local root = arg[0]:match("^(.*)/compiler/[^/]*$") or "."
package.path = root .. "/?.lua"

local diag = require("compiler.diag")
local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local lower = require("compiler.lower")
local emit = require("compiler.emit")

local function fail(message)
  io.stderr:write(message, "\n")
  os.exit(1)
end

-- Checks the whole program and, for run, returns it as a loaded Lua chunk.
local function compile(command, path, source)
  local program = parser.parse(lexer.lex(source))
  bind.bind(program)
  check.check(program)
  if command == "run" then
    return assert(load(emit.emit(lower.lower(program), path), "=" .. path))
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

local command, path = arg[1], arg[2]
if #arg ~= 2 or (command ~= "check" and command ~= "run") then
  fail("usage: willow check <file>\n       willow run <file>")
end

local file, err = io.open(path, "rb")
if not file then
  fail("error: " .. err)
end
local source, read_err = file:read("*a")
file:close()
if not source then
  fail("error: " .. path .. ": " .. read_err)
end

local ok, result = xpcall(compile, report, command, path, source)
if not ok then
  if not diag.is(result) then
    fail(result)
  end
  local lines = {}
  for i, d in ipairs(result) do
    lines[i] = diag.format(path, d)
  end
  fail(table.concat(lines, "\n"))
end
if command == "run" then
  result()
end
