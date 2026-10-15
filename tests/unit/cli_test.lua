local function eq(expected, actual)
  if expected ~= actual then
    error(string.format("expected %q, got %q", tostring(expected), tostring(actual)), 2)
  end
end

local function quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function capture(command)
  local shell = io.popen(command)
  local text = shell:read("*a")
  shell:close()
  return text
end

local ROOT = capture("cd " .. quote(arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. " && pwd"):gsub("\n$", "")
local WILLOW = ROOT .. "/willow"
local LUAJIT = ROOT .. "/vendor/luajit/src/luajit"
local USAGE = "usage: willow check <file>\n       willow run <file>\n       willow build <file> -o <output>\n"

-- Runs `command` in `dir`; returns its exit status, stdout, and stderr.
local function sh(dir, command)
  local out, err = os.tmpname(), os.tmpname()
  local status = tonumber(capture(string.format("cd %s && %s >%s 2>%s; echo $?",
    quote(dir), command, quote(out), quote(err))))
  local stdout, stderr = read(out), read(err)
  os.remove(out)
  os.remove(err)
  return status, stdout, stderr
end

local function willow(dir, args)
  return sh(dir, quote(WILLOW) .. " " .. args)
end

-- Calls `test` with a fresh directory whose path contains a space, then
-- removes it.
local function in_temp_dir(test)
  local base = capture("mktemp -d"):gsub("\n$", "")
  local dir = base .. "/with space"
  os.execute("mkdir " .. quote(dir))
  local ok, err = pcall(test, dir, base)
  os.execute("rm -rf " .. quote(base))
  if not ok then
    error(err, 0)
  end
end

local PROGRAM = "def main() -> None:\n    print(1)\n"

return {
  usage_errors = function()
    in_temp_dir(function(dir)
      local cases = {
        { "", "error: missing command" },
        { "compile x.wlo", "error: unknown command 'compile'" },
        { "run -x x.wlo", "error: unknown option '-x'" },
        { "run a.wlo b.wlo", "error: unexpected argument 'b.wlo'" },
        { "run a.wlo -o out.lua", "error: unknown option '-o'" },
        { "build a.wlo", "error: build needs -o <output>" },
        { "build a.wlo -o", "error: -o needs a path" },
        { "build a.wlo -o x.lua -o y.lua", "error: -o given more than once" },
        { "check", "error: missing input file" },
      }
      for _, case in ipairs(cases) do
        local status, stdout, stderr = willow(dir, case[1])
        eq(1, status)
        eq("", stdout)
        eq(case[2] .. "\n" .. USAGE, stderr)
      end
    end)
  end,

  check_does_not_execute = function()
    in_temp_dir(function(dir)
      write(dir .. "/prog.wlo", PROGRAM)
      local status, stdout, stderr = willow(dir, "check prog.wlo")
      eq(0, status)
      eq("", stdout)
      eq("", stderr)
      write(dir .. "/bad.wlo", "def main() -> None:\n    print(x)\n")
      status, stdout, stderr = willow(dir, "check bad.wlo")
      eq(1, status)
      eq("bad.wlo:2:11: error: unknown name 'x'\n", stderr)
    end)
  end,

  build_matches_run = function()
    in_temp_dir(function(dir, base)
      write(dir .. "/prog.wlo", table.concat({
        "def twice(n: int) -> int:",
        "    return n * 2",
        "def main() -> None:",
        "    print(twice(21))",
        "    print(twice(9007199254740991))",
      }, "\n"))
      local run_status, run_out, run_err = willow(dir, "run prog.wlo")
      eq(1, run_status)
      eq("42\n", run_out)
      local status, stdout, stderr = willow(dir, "build prog.wlo -o 'out file.lua'")
      eq(0, status)
      eq("", stdout)
      eq("", stderr)
      eq(nil, read(dir .. "/out file.lua.tmp"))
      local elsewhere = base .. "/elsewhere"
      os.execute("mkdir " .. quote(elsewhere))
      write(elsewhere .. "/copy.lua", read(dir .. "/out file.lua"))
      status, stdout, stderr = sh(elsewhere, quote(LUAJIT) .. " copy.lua")
      eq(run_status, status)
      eq(run_out, stdout)
      eq(run_err, stderr)
    end)
  end,

  failed_build_preserves_output = function()
    in_temp_dir(function(dir)
      write(dir .. "/out.lua", "old")
      write(dir .. "/bad.wlo", "def main() -> None:\n    x = 1 + 'a'\n")
      local status = willow(dir, "build bad.wlo -o out.lua")
      eq(1, status)
      eq("old", read(dir .. "/out.lua"))
      eq(nil, read(dir .. "/out.lua.tmp"))
    end)
  end,

  output_alias_rejected = function()
    in_temp_dir(function(dir)
      write(dir .. "/prog.wlo", PROGRAM)
      sh(dir, "ln -s prog.wlo link.lua && ln prog.wlo hard.lua")
      for _, output in ipairs({ "prog.wlo", "./prog.wlo", "../with space/prog.wlo", "link.lua", "hard.lua" }) do
        local status, stdout, stderr = willow(dir, "build prog.wlo -o " .. quote(output))
        eq(1, status)
        eq("error: output " .. output .. " is the input file\n", stderr)
      end
      eq(PROGRAM, read(dir .. "/prog.wlo"))
    end)
  end,

  unwritable_output = function()
    in_temp_dir(function(dir)
      write(dir .. "/prog.wlo", PROGRAM)
      local status, _, stderr = willow(dir, "build prog.wlo -o missing/out.lua")
      eq(1, status)
      assert(stderr:find("error: cannot write missing/out.lua: ", 1, true) == 1, stderr)
    end)
  end,
}
