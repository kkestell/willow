-- Runs the test files named on the command line.
--
-- A `.lua` file is a unit test file that returns a table of test functions; a
-- test fails by raising an error.
--
-- A `.wlo` file is a program test, run as `willow run NAME.wlo` from its own
-- directory. Optional `NAME.out` and `NAME.err` hold the expected stdout and
-- stderr; a missing file means no output. The expected exit status is 1 when
-- `NAME.err` exists and 0 otherwise. Stdin is `NAME.in` when it exists and
-- empty otherwise.

local root = (arg[0]:match("^(.*)/tests/[^/]*$") or ".")
package.path = root .. "/?.lua"

local quote = require("compiler.runner").quote
local read = require("compiler.loader").read

-- Program tests change directory, so the launcher path must be absolute.
local pwd = io.popen("cd " .. quote(root) .. " && pwd")
local willow = pwd:read("*l") .. "/willow"
pwd:close()

local function compare(what, expected, actual)
  if expected ~= actual then
    error(string.format("%s differs\n--- expected\n%s\n--- actual\n%s", what, expected, actual), 0)
  end
end

local function run_program(file)
  local dir, name = file:match("^(.-)([^/]*)$")
  local base = file:sub(1, -5)
  local out, err = os.tmpname(), os.tmpname()
  local input = read(base .. ".in") and name:sub(1, -5) .. ".in" or "/dev/null"
  local shell = io.popen(string.format("cd %s && %s run %s <%s >%s 2>%s; echo $?",
    quote(dir == "" and "." or dir), quote(willow), quote(name), quote(input), quote(out), quote(err)))
  local status = shell:read("*n")
  shell:close()
  local stdout, stderr = read(out), read(err)
  os.remove(out)
  os.remove(err)
  local expected_err = read(base .. ".err")
  compare("exit status", tostring(expected_err and 1 or 0), tostring(status))
  compare("stdout", read(base .. ".out") or "", stdout)
  compare("stderr", expected_err or "", stderr)
end

local passed, failed = 0, 0

local function record(label, ok, err)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write("FAIL ", label, ": ", tostring(err), "\n")
  end
end

for _, file in ipairs(arg) do
  if file:match("%.wlo$") then
    record(file, pcall(run_program, file))
  else
    local tests = dofile(file)
    local names = {}
    for name in pairs(tests) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      record(file .. " " .. name, pcall(tests[name]))
    end
  end
end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
