-- Runs the test files named on the command line. Each test file returns a table
-- of test functions; a test fails by raising an error.

local root = (arg[0]:match("^(.*)/tests/[^/]*$") or ".")
package.path = root .. "/?.lua"

local passed, failed = 0, 0
for _, file in ipairs(arg) do
  local tests = dofile(file)
  local names = {}
  for name in pairs(tests) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, err = pcall(tests[name])
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      io.stderr:write("FAIL ", file, " ", name, ": ", tostring(err), "\n")
    end
  end
end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
