local eq = require("tests.support").eq
local quote = require("compiler.runner").quote

local function capture(command)
  local shell = io.popen(command)
  local text = shell:read("*a")
  shell:close()
  return text
end

local ROOT = capture("cd " .. quote(arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. " && pwd"):gsub("\n$", "")

-- Runs a program that prints a new temporary file and directory with the
-- environment `tmpdir` (an assignment such as TMPDIR=/x), removes both, and
-- returns the printed paths.
local function temporary_paths(tmpdir)
  local scratch = capture("mktemp -d"):gsub("\n$", "")
  local file = assert(io.open(scratch .. "/main.wlo", "wb"))
  file:write("import fs\ndef main():\n    print(fs.temp_file())\n    print(fs.temp_dir())\n")
  file:close()
  local output = capture(string.format("cd %s && env %s %s run main.wlo", quote(scratch), tmpdir, quote(ROOT .. "/willow")))
  local paths = {}
  for path in output:gmatch("[^\n]+") do
    paths[#paths + 1] = path
    os.execute("rm -rf " .. quote(path))
  end
  os.execute("rm -rf " .. quote(scratch))
  return paths
end

return {
  temp_parent_is_tmpdir = function()
    local dir = capture("mktemp -d"):gsub("\n$", "")
    local paths = temporary_paths("TMPDIR=" .. quote(dir))
    os.execute("rmdir " .. quote(dir))
    eq(2, #paths)
    for _, path in ipairs(paths) do
      assert(path:find(dir .. "/willow-", 1, true) == 1, path)
    end
  end,

  temp_parent_defaults_to_tmp = function()
    local paths = temporary_paths("TMPDIR=")
    eq(2, #paths)
    for _, path in ipairs(paths) do
      assert(path:find("/tmp/willow-", 1, true) == 1, path)
    end
  end,
}
