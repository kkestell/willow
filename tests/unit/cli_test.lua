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
local USAGE = "usage: willow check <file>\n       willow run <file> [args...]\n"
  .. "       willow compile <file> -o <output>\n       willow build <file> -o <output>\n"

local JSON_PROGRAM = "import json\ndef main() -> None:\n    print(json.dump(json.parse('[1, 2.5]')))\n"

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
        { "make x.wlo", "error: unknown command 'make'" },
        { "run -x x.wlo", "error: unknown option '-x'" },
        { "check a.wlo b.wlo", "error: unexpected argument 'b.wlo'" },
        { "check a.wlo -o out.lua", "error: unknown option '-o'" },
        { "compile a.wlo -o out.lua b.wlo", "error: unexpected argument 'b.wlo'" },
        { "build a.wlo -o out b.wlo", "error: unexpected argument 'b.wlo'" },
        { "compile a.wlo", "error: compile needs -o <output>" },
        { "build a.wlo", "error: build needs -o <output>" },
        { "compile a.wlo -o", "error: -o needs a path" },
        { "compile a.wlo -o x.lua -o y.lua", "error: -o given more than once" },
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

  compile_matches_run = function()
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
      local status, stdout, stderr = willow(dir, "compile prog.wlo -o 'out file.lua'")
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

  modules_compile_matches_run = function()
    in_temp_dir(function(dir, base)
      write(dir .. "/util.wlo", "def twice(n: int) -> int:\n    return n * 2\n")
      write(dir .. "/prog.wlo", "import util\ndef main() -> None:\n    print(util.twice(21))\n")
      local run_status, run_out = willow(dir, "run prog.wlo")
      eq(0, run_status)
      eq("42\n", run_out)
      eq(0, (willow(dir, "compile prog.wlo -o out.lua")))
      local elsewhere = base .. "/elsewhere"
      os.execute("mkdir " .. quote(elsewhere))
      write(elsewhere .. "/copy.lua", read(dir .. "/out.lua"))
      local status, stdout = sh(elsewhere, quote(LUAJIT) .. " copy.lua")
      eq(0, status)
      eq(run_out, stdout)
      local module = read(dir .. "/util.wlo")
      local stderr
      status, _, stderr = willow(dir, "compile prog.wlo -o util.wlo")
      eq(1, status)
      eq("error: output util.wlo is the module file util.wlo\n", stderr)
      eq(module, read(dir .. "/util.wlo"))
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
      local status, stdout, stderr = willow(dir, "build prog.wlo -o 'out file'")
      eq(0, status)
      eq("", stdout)
      eq("", stderr)
      eq(nil, read(dir .. "/out file.tmp"))
      local elsewhere = base .. "/elsewhere"
      os.execute("mkdir " .. quote(elsewhere))
      os.execute("cp " .. quote(dir .. "/out file") .. " " .. quote(elsewhere .. "/copy"))
      status, stdout, stderr = sh(elsewhere, "./copy")
      eq(run_status, status)
      eq(run_out, stdout)
      eq(run_err, stderr)
    end)
  end,

  modules_build_matches_run = function()
    in_temp_dir(function(dir, base)
      write(dir .. "/util.wlo", "def twice(n: int) -> int:\n    return n * 2\n")
      write(dir .. "/prog.wlo", "import util\ndef main() -> None:\n    print(util.twice(21))\n")
      eq(0, (willow(dir, "build prog.wlo -o out")))
      local elsewhere = base .. "/elsewhere"
      os.execute("mkdir " .. quote(elsewhere))
      os.execute("cp " .. quote(dir .. "/out") .. " " .. quote(elsewhere .. "/copy"))
      local status, stdout = sh(elsewhere, "./copy")
      eq(0, status)
      eq("42\n", stdout)
      local module = read(dir .. "/util.wlo")
      local stderr
      status, _, stderr = willow(dir, "build prog.wlo -o util.wlo")
      eq(1, status)
      eq("error: output util.wlo is the module file util.wlo\n", stderr)
      eq(module, read(dir .. "/util.wlo"))
    end)
  end,

  unreadable_module = function()
    in_temp_dir(function(dir)
      os.execute("mkdir " .. quote(dir .. "/util.wlo"))
      write(dir .. "/prog.wlo", "import util\ndef main() -> None:\n    pass\n")
      local status, _, stderr = willow(dir, "check prog.wlo")
      eq(1, status)
      eq("prog.wlo:1:8: error: cannot load module 'util': util.wlo: Is a directory\n", stderr)
    end)
  end,

  failed_compile_preserves_output = function()
    in_temp_dir(function(dir)
      write(dir .. "/out.lua", "old")
      write(dir .. "/bad.wlo", "def main() -> None:\n    x = 1 + 'a'\n")
      local status = willow(dir, "compile bad.wlo -o out.lua")
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
        local status, stdout, stderr = willow(dir, "compile prog.wlo -o " .. quote(output))
        eq(1, status)
        eq("error: output " .. output .. " is the input file\n", stderr)
      end
      eq(PROGRAM, read(dir .. "/prog.wlo"))
    end)
  end,

  unwritable_output = function()
    in_temp_dir(function(dir)
      write(dir .. "/prog.wlo", PROGRAM)
      local status, _, stderr = willow(dir, "compile prog.wlo -o missing/out.lua")
      eq(1, status)
      assert(stderr:find("error: cannot write missing/out.lua: ", 1, true) == 1, stderr)
    end)
  end,

  arguments_reach_sys_args = function()
    in_temp_dir(function(dir)
      write(dir .. "/prog.wlo", table.concat({
        "import sys",
        "def main() -> None:",
        "    first = sys.args()",
        "    args = sys.args()",
        "    print(len(args))",
        "    for a in args:",
        "        print(a)",
        "",
      }, "\n"))
      local args = " a -o --x 'b c'"
      local expected = "4\na\n-o\n--x\nb c\n"
      local status, stdout = willow(dir, "run prog.wlo" .. args)
      eq(0, status)
      eq(expected, stdout)
      eq(0, (willow(dir, "compile prog.wlo -o out.lua")))
      status, stdout = sh(dir, quote(LUAJIT) .. " out.lua" .. args)
      eq(0, status)
      eq(expected, stdout)
      eq(0, (willow(dir, "build prog.wlo -o out")))
      status, stdout = sh(dir, "./out" .. args)
      eq(0, status)
      eq(expected, stdout)
    end)
  end,

  invalid_utf8_argument = function()
    in_temp_dir(function(dir)
      write(dir .. "/prog.wlo", table.concat({
        "import sys",
        "def main() -> None:",
        "    print(1)",
        "    try:",
        "        sys.args()",
        "    except ValueError as error:",
        "        print(error.message)",
        "    sys.args()",
        "",
      }, "\n"))
      local status, stdout, stderr = willow(dir, "run prog.wlo ok \"$(printf '\\377')\"")
      eq(1, status)
      eq("1\ninvalid UTF-8\n", stdout)
      eq("prog.wlo:8:9: error: ValueError: invalid UTF-8\n  in main at prog.wlo:8:9\n", stderr)
    end)
  end,

  exit_status = function()
    in_temp_dir(function(dir)
      write(dir .. "/three.wlo", "import sys\ndef main() -> None:\n    print(1)\n    sys.exit(3)\n")
      local status, stdout, stderr = willow(dir, "run three.wlo")
      eq(3, status)
      eq("1\n", stdout)
      eq("", stderr)
      eq(0, (willow(dir, "build three.wlo -o three")))
      status, stdout = sh(dir, "./three")
      eq(3, status)
      eq("1\n", stdout)
      write(dir .. "/finally.wlo", "import sys\ndef main() -> None:\n    try:\n        sys.exit(0)\n    finally:\n        print(1)\n")
      status, stdout = willow(dir, "run finally.wlo")
      eq(0, status)
      eq("", stdout)
      for _, value in ipairs({ "256", "-1" }) do
        write(dir .. "/range.wlo", "import sys\ndef main() -> None:\n    sys.exit(" .. value .. ")\n")
        status, stdout, stderr = willow(dir, "run range.wlo")
        eq(1, status)
        eq("range.wlo:3:9: error: ValueError: exit status out of range\n  in main at range.wlo:3:9\n", stderr)
      end
    end)
  end,

  file_round_trip = function()
    in_temp_dir(function(dir)
      local text = "caf\195\169\r\nline\n"
      write(dir .. "/prog.wlo", table.concat({
        "import fs",
        "def main() -> None:",
        "    text = 'caf\\u00e9\\r\\nline\\n'",
        "    fs.write_file('out.txt', text)",
        "    print(fs.read_file('out.txt') == text)",
        "    try:",
        "        fs.write_file('missing/out.txt', text)",
        "    except OSError as error:",
        "        print(error.message.startswith('cannot write missing/out.txt: '))",
      }, "\n"))
      local status, stdout = willow(dir, "run prog.wlo")
      eq(0, status)
      eq("True\nTrue\n", stdout)
      eq(text, read(dir .. "/out.txt"))
    end)
  end,

  number_example = function()
    in_temp_dir(function(dir)
      local example = quote(ROOT .. "/examples/number.wlo")
      local status, stdout = sh(dir, "printf 'apple\\nbanana\\n' | " .. quote(WILLOW) .. " run " .. example .. " out.txt")
      eq(0, status)
      eq("wrote 2 lines\n", stdout)
      eq("1: apple\n2: banana\n", read(dir .. "/out.txt"))
      local stderr
      status, stdout, stderr = willow(dir, "run " .. example .. " </dev/null")
      eq(2, status)
      eq("usage: number <output>\n", stderr)
    end)
  end,

  chars_example = function()
    in_temp_dir(function(dir)
      local example = quote(ROOT .. "/examples/chars.wlo")
      local status, stdout, stderr = willow(dir, "run " .. example)
      eq(2, status)
      eq("", stdout)
      eq("usage: chars <file>\n", stderr)
      status, stdout, stderr = willow(dir, "run " .. example .. " missing.txt")
      eq(1, status)
      eq("cannot read missing.txt: No such file or directory\n", stderr)
      write(dir .. "/text.txt", "h\195\169llo\n")
      status, stdout, stderr = willow(dir, "run " .. example .. " text.txt")
      eq(0, status)
      eq("6\n", stdout)
      eq("", stderr)
    end)
  end,

  standard_library_build_runs_elsewhere = function()
    in_temp_dir(function(dir, base)
      write(dir .. "/prog.wlo", JSON_PROGRAM)
      local run_status, run_out = willow(dir, "run prog.wlo")
      eq(0, run_status)
      eq("[1,2.5]\n", run_out)
      eq(0, (willow(dir, "build prog.wlo -o out")))
      local elsewhere = base .. "/elsewhere"
      os.execute("mkdir " .. quote(elsewhere))
      os.execute("cp " .. quote(dir .. "/out") .. " " .. quote(elsewhere .. "/copy"))
      local status, stdout = sh(elsewhere, "./copy")
      eq(0, status)
      eq(run_out, stdout)
    end)
  end,

  standard_library_through_symlink = function()
    in_temp_dir(function(dir)
      write(dir .. "/prog.wlo", JSON_PROGRAM)
      os.execute("ln -s " .. quote(WILLOW) .. " " .. quote(dir .. "/willow"))
      local status, stdout = sh(dir, "./willow run prog.wlo")
      eq(0, status)
      eq("[1,2.5]\n", stdout)
    end)
  end,
}
