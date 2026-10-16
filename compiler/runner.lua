-- The test command: discovers test files, checks them all, then runs each
-- `test_*` function in its own process.
local M = {}

local function quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- The test files at `path`, sorted: the `test_*.wlo` files inside a
-- directory, directly or, when `recursive`, at any depth without following
-- directory symlinks; or the path itself.
function M.discover(path, recursive)
  if os.execute("test -d " .. quote(path)) ~= 0 then
    return { path }
  end
  local shell = io.popen("find " .. quote(path) .. (recursive and "" or " -maxdepth 1")
    .. " -type f -name 'test_*.wlo'")
  -- find prints each file after the starting path as given.
  local prefix = path == "." and "" or path:gsub("/+$", "") .. "/"
  local files = {}
  for line in shell:lines() do
    files[#files + 1] = prefix .. line:sub(#path + 1):gsub("^/+", "")
  end
  shell:close()
  table.sort(files)
  return files
end

-- Runs test `name` of the test chunk at `lua_path` with no arguments and empty
-- stdin. Returns whether it returned normally, its exit status, and its
-- combined output.
local function run_test(luajit, lua_path, name)
  local result = os.tmpname()
  os.remove(result)
  local shell = io.popen(string.format("%s %s %s %s </dev/null 2>&1; printf '\\n%%d' $?",
    quote(luajit), quote(lua_path), quote(name), quote(result)))
  local text = shell:read("*a")
  shell:close()
  local output, status = text:match("^(.*)\n(%d+)$")
  return os.remove(result) ~= nil, status, output
end

-- Runs the test command and returns its exit status. `compile(file)` returns
-- the file's test chunk and its test names, or false and its diagnostics.
function M.test(luajit, path, check_only, compile, recursive)
  local files = M.discover(path, recursive)
  local chunks, names, failed_checks, count = {}, {}, false, 0
  for i, file in ipairs(files) do
    local text, tests = compile(file)
    if text then
      chunks[i], names[i] = text, tests
      count = count + #tests
    else
      io.stderr:write(tests, "\n")
      failed_checks = true
    end
  end
  if failed_checks then
    return 1
  elseif count == 0 then
    io.stderr:write("error: no tests found in " .. path .. "\n")
    return 1
  elseif check_only then
    return 0
  end

  local passed, failed = 0, 0
  for i, file in ipairs(files) do
    local lua_path = os.tmpname()
    local out = assert(io.open(lua_path, "wb"))
    out:write(chunks[i])
    out:close()
    for _, name in ipairs(names[i]) do
      local returned, status, output = run_test(luajit, lua_path, name)
      if returned and status == "0" then
        passed = passed + 1
        io.stdout:write("PASS ", file, " ", name, "\n")
      else
        failed = failed + 1
        io.stdout:write("FAIL ", file, " ", name, "\n")
        for line in output:gsub("([^\n])$", "%1\n"):gmatch("(.-)\n") do
          io.stdout:write(line == "" and "" or "  " .. line, "\n")
        end
        if returned then
          io.stdout:write("  exit status ", status, "\n")
        else
          io.stdout:write("  test did not return (exit status ", status, ")\n")
        end
      end
      io.stdout:flush()
    end
    os.remove(lua_path)
  end
  io.stdout:write(passed, " passed, ", failed, " failed\n")
  return failed == 0 and 0 or 1
end

return M
