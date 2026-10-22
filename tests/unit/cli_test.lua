local eq = require("tests.support").eq
local quote = require("compiler.runner").quote
local read = require("compiler.loader").read

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
local USAGE = "usage: willow init\n       willow check [file]\n       willow run [file [args...] | -- args...]\n"
  .. "       willow compile [file] -o <output>\n       willow build [file] -o <output>\n"
  .. "       willow test [--check] [path]\n"
  .. "Without a file, the command uses willow.json in the current directory.\n"

local ffi = require("ffi")
ffi.cdef([[
int posix_openpt(int flags);
int grantpt(int fd);
int unlockpt(int fd);
char *ptsname(int fd);
int open(const char *path, int flags, ...);
long read(int fd, void *buffer, size_t size);
int close(int fd);
int fcntl(int fd, int command, ...);
]])
local OSX = ffi.os == "OSX"

-- Runs `command` with stdout and stderr on a new terminal and returns what it
-- wrote there, without the carriage returns the terminal adds before newlines.
-- The test keeps the terminal open so the output stays readable afterwards.
local function in_terminal(dir, command)
  local master = ffi.C.posix_openpt(OSX and 0x20002 or 0x102) -- O_RDWR | O_NOCTTY
  assert(master >= 0 and ffi.C.grantpt(master) == 0 and ffi.C.unlockpt(master) == 0)
  local slave_path = ffi.string(ffi.C.ptsname(master))
  local slave = ffi.C.open(slave_path, OSX and 0x20002 or 0x102)
  os.execute(string.format("cd %s && %s >%s 2>&1 </dev/null", quote(dir), command, quote(slave_path)))
  ffi.C.fcntl(master, 4, ffi.new("int", OSX and 0x4 or 0x800)) -- F_SETFL, O_NONBLOCK
  local buffer, parts = ffi.new("char[4096]"), {}
  while true do
    local count = tonumber(ffi.C.read(master, buffer, 4096))
    if count <= 0 then
      break
    end
    parts[#parts + 1] = ffi.string(buffer, count)
  end
  ffi.C.close(slave)
  ffi.C.close(master)
  return (table.concat(parts):gsub("\r\n", "\n"))
end

-- Starts a background command whose first stdout line is ready once `path`
-- holds it, and returns its pid.
local function start_server(command, path)
  local shell = io.popen(command .. " >" .. quote(path) .. " 2>/dev/null & echo $!")
  local pid = shell:read("*l")
  shell:close()
  return pid
end

-- Calls `test` with the base URL of a running tests/http_server.lua.
local function with_http_server(test)
  local port_file = os.tmpname()
  local pid = start_server(quote(LUAJIT) .. " " .. quote(ROOT .. "/tests/http_server.lua"), port_file)
  local port
  for _ = 1, 100 do
    port = (read(port_file) or ""):match("^(%d+)\n")
    if port then
      break
    end
    os.execute("sleep 0.05")
  end
  local ok, err = pcall(test, "http://127.0.0.1:" .. assert(port, "test server did not start"), port)
  os.execute("kill " .. pid)
  os.remove(port_file)
  if not ok then
    error(err, 0)
  end
end

local JSON_PROGRAM = "import json\ndef main():\n    print(json.dump(json.parse('[1, 2.5]')))\n"

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

local PROGRAM = "def main():\n    print(1)\n"

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
      write(dir .. "/bad.wlo", "def main():\n    print(x)\n")
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
        "def main():",
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
      write(dir .. "/prog.wlo", "import util\ndef main():\n    print(util.twice(21))\n")
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
        "def main():",
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
      write(dir .. "/prog.wlo", "import util\ndef main():\n    print(util.twice(21))\n")
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
      write(dir .. "/prog.wlo", "import util\ndef main():\n    pass\n")
      local status, _, stderr = willow(dir, "check prog.wlo")
      eq(1, status)
      eq("prog.wlo:1:8: error: cannot load module 'util': util.wlo: Is a directory\n", stderr)
    end)
  end,

  failed_compile_preserves_output = function()
    in_temp_dir(function(dir)
      write(dir .. "/out.lua", "old")
      write(dir .. "/bad.wlo", "def main():\n    x = 1 + 'a'\n")
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
        "def main():",
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
        "def main():",
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
      write(dir .. "/three.wlo", "import sys\ndef main():\n    print(1)\n    sys.exit(3)\n")
      local status, stdout, stderr = willow(dir, "run three.wlo")
      eq(3, status)
      eq("1\n", stdout)
      eq("", stderr)
      eq(0, (willow(dir, "build three.wlo -o three")))
      status, stdout = sh(dir, "./three")
      eq(3, status)
      eq("1\n", stdout)
      write(dir .. "/finally.wlo", "import sys\ndef main():\n    try:\n        sys.exit(0)\n    finally:\n        print(1)\n")
      status, stdout = willow(dir, "run finally.wlo")
      eq(0, status)
      eq("", stdout)
      for _, value in ipairs({ "256", "-1" }) do
        write(dir .. "/range.wlo", "import sys\ndef main():\n    sys.exit(" .. value .. ")\n")
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
        "def main():",
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
      local program = quote(ROOT .. "/tests/fixtures/number.wlo")
      local status, stdout = sh(dir, "printf 'apple\\nbanana\\n' | " .. quote(WILLOW) .. " run " .. program .. " out.txt")
      eq(0, status)
      eq("wrote 2 lines\n", stdout)
      eq("1: apple\n2: banana\n", read(dir .. "/out.txt"))
      local stderr
      status, stdout, stderr = willow(dir, "run " .. program .. " </dev/null")
      eq(2, status)
      eq("usage: number <output>\n", stderr)
    end)
  end,

  shapes_example = function()
    local program = "tests/fixtures/shapes.wlo"
    local status, stdout = willow(ROOT, "run " .. program .. " 3x4 2x2.5")
    eq(0, status)
    eq("3x4: 12.0 (doubled 48.0)\n2x2.5: 5.0 (doubled 20.0)\ntotal 17.0\n", stdout)
    local stderr
    status, stdout, stderr = willow(ROOT, "run " .. program .. " 2xab")
    eq(2, status)
    eq("2xab: not a number\n", stderr)
  end,

  chars_example = function()
    in_temp_dir(function(dir)
      local program = quote(ROOT .. "/tests/fixtures/chars.wlo")
      local status, stdout, stderr = willow(dir, "run " .. program)
      eq(2, status)
      eq("", stdout)
      eq("usage: chars <file>\n", stderr)
      status, stdout, stderr = willow(dir, "run " .. program .. " missing.txt")
      eq(1, status)
      eq("cannot read missing.txt: No such file or directory\n", stderr)
      write(dir .. "/text.txt", "h\195\169llo\n")
      status, stdout, stderr = willow(dir, "run " .. program .. " text.txt")
      eq(0, status)
      eq("6\n", stdout)
      eq("", stderr)
    end)
  end,

  word_frequency_regression = function()
    in_temp_dir(function(dir)
      local program = quote(ROOT .. "/tests/fixtures/words.wlo")
      local status, stdout = sh(dir, "printf 'The cat and the dog\\nthe Stra\\303\\237e and STRASSE\\n\\n  cat\\n' | "
        .. quote(WILLOW) .. " run " .. program)
      eq(0, status)
      eq(table.concat({
        "word         count    share",
        "the              3    30.0%",
        "and              2    20.0%",
        "cat              2    20.0%",
        "dog              1    10.0%",
        "strasse          1    10.0%",
        "stra\195\159e           1    10.0%",
        "",
      }, "\n"), stdout)
    end)
  end,

  banner_example = function()
    in_temp_dir(function(dir)
      local program = quote(ROOT .. "/tests/fixtures/banner.wlo")
      local status, stdout = willow(dir, "run " .. program .. " hello world")
      eq(0, status)
      eq("************************\n* hello world          *\n************************\n", stdout)
      status, stdout = willow(dir, "run " .. program .. " --upper --border=# --width=10 hello world")
      eq(0, status)
      eq("###############\n# HELLO WORLD #\n###############\n", stdout)
    end)
  end,

  cart_example_tests_pass = function()
    local status, stdout, stderr = willow(ROOT, "test tests/fixtures/cart")
    eq(0, status)
    eq(table.concat({
      "PASS tests/fixtures/cart/test_cart.wlo test_discount_out_of_range",
      "PASS tests/fixtures/cart/test_cart.wlo test_discount_rounds_down",
      "PASS tests/fixtures/cart/test_cart.wlo test_empty_cart_totals_zero",
      "PASS tests/fixtures/cart/test_cart.wlo test_subtotal_counts_quantities",
      "4 passed, 0 failed",
      "",
    }, "\n"), stdout)
    eq("", stderr)
    status, stdout = willow(ROOT, "run tests/fixtures/cart/main.wlo")
    eq(0, status)
    eq("tea         2     9.00\nscone       1     3.25\ndiscount           10%\ntotal            11.03\n", stdout)
  end,

  failing_tests_report = function()
    local status, stdout, stderr = willow(ROOT, "test tests/suites/failing")
    eq(1, status)
    eq(table.concat({
      "PASS tests/suites/failing/test_shop.wlo test_async_known_price",
      "FAIL tests/suites/failing/test_shop.wlo test_async_unknown_item",
      "  tests/suites/failing/shop.wlo:4:5: error: KeyError: no price for cake",
      "    in price at tests/suites/failing/shop.wlo:4:5",
      "    called from priced at tests/suites/failing/test_shop.wlo:25:17",
      "    called from test_async_unknown_item at tests/suites/failing/test_shop.wlo:31:5",
      "  test did not return (exit status 1)",
      "FAIL tests/suites/failing/test_shop.wlo test_exit_is_a_failure",
      "  test did not return (exit status 0)",
      "PASS tests/suites/failing/test_shop.wlo test_isolated_process",
      "PASS tests/suites/failing/test_shop.wlo test_known_price",
      "PASS tests/suites/failing/test_shop.wlo test_output_of_passing_tests_is_hidden",
      "FAIL tests/suites/failing/test_shop.wlo test_unknown_item",
      "  tests/suites/failing/shop.wlo:4:5: error: KeyError: no price for cake",
      "    in price at tests/suites/failing/shop.wlo:4:5",
      "    called from test_unknown_item at tests/suites/failing/test_shop.wlo:12:10",
      "  test did not return (exit status 1)",
      "FAIL tests/suites/failing/test_shop.wlo test_wrong_price",
      "  checking tea",
      "  tests/suites/failing/test_shop.wlo:9:5: error: AssertionError: tea should cost 400",
      "    in test_wrong_price at tests/suites/failing/test_shop.wlo:9:5",
      "  test did not return (exit status 1)",
      "4 passed, 4 failed",
      "",
    }, "\n"), stdout)
    eq("", stderr)
    status, stdout, stderr = willow(ROOT, "test --check tests/suites/failing")
    eq(0, status)
    eq("", stdout)
    eq("", stderr)
  end,

  async_tests_run_task_groups = function()
    local status, stdout = willow(ROOT, "test tests/suites/async")
    eq(1, status)
    eq(table.concat({
      "PASS tests/suites/async/test_groups.wlo test_double",
      "FAIL tests/suites/async/test_groups.wlo test_halve_odd",
      "  tests/suites/async/test_groups.wlo:9:9: error: ValueError: odd",
      "    in halve at tests/suites/async/test_groups.wlo:9:9",
      "    in task started at tests/suites/async/test_groups.wlo:19:15",
      "  test did not return (exit status 1)",
      "1 passed, 1 failed",
      "",
    }, "\n"), stdout)
  end,

  async_tests_run_in_the_event_loop = function()
    in_temp_dir(function(dir)
      write(dir .. "/test_sleep.wlo", "import aio\n"
        .. "async def test_sleeps():\n    await aio.sleep(0.0)\n    print('woke')\n"
        .. "async def test_bad_sleep():\n    await aio.sleep(-1.0)\n")
      local status, stdout = willow(dir, "test")
      eq(1, status)
      eq("FAIL test_sleep.wlo test_bad_sleep\n"
        .. "  test_sleep.wlo:6:15: error: ValueError: sleep length must be finite and nonnegative\n"
        .. "    in test_bad_sleep at test_sleep.wlo:6:5\n  test did not return (exit status 1)\n"
        .. "PASS test_sleep.wlo test_sleeps\n1 passed, 1 failed\n", stdout)
    end)
  end,

  test_command_checks_before_running = function()
    in_temp_dir(function(dir)
      write(dir .. "/test_a.wlo", "def test_a():\n    print('ran')\n    assert False\n")
      write(dir .. "/test_b.wlo", "def test_b():\n    x: int = 'b'\n")
      write(dir .. "/helper.wlo", "def io():\n    pass\ndef test_helper():\n    pass\n")
      local status, stdout, stderr = willow(dir, "test")
      eq(1, status)
      eq("", stdout)
      eq("test_b.wlo:2:14: error: expected int, received str\n", stderr)
      status, stdout, stderr = willow(dir, "test helper.wlo")
      eq(0, status)
      eq("PASS helper.wlo test_helper\n1 passed, 0 failed\n", stdout)
      os.remove(dir .. "/test_b.wlo")
      status, stdout = willow(dir, "test .")
      eq(1, status)
      eq("FAIL test_a.wlo test_a\n  ran\n  test_a.wlo:3:5: error: AssertionError: assertion failed\n"
        .. "    in test_a at test_a.wlo:3:5\n  test did not return (exit status 1)\n0 passed, 1 failed\n", stdout)
      write(dir .. "/test_c.wlo", "def test_c(x: int):\n    pass\n")
      status, stdout, stderr = willow(dir, "test --check")
      eq(1, status)
      eq("test_c.wlo:1:5: error: test function 'test_c' must take no parameters and return None\n", stderr)
      write(dir .. "/test_c.wlo", "async def test_c() -> int:\n    return 1\n")
      status, stdout, stderr = willow(dir, "test --check")
      eq(1, status)
      eq("test_c.wlo:1:11: error: test function 'test_c' must take no parameters and return None\n", stderr)
      os.execute("mkdir " .. quote(dir .. "/empty"))
      status, stdout, stderr = willow(dir, "test --check empty")
      eq(1, status)
      eq("error: no tests found in empty\n", stderr)
      status, stdout, stderr = willow(dir, "test --verbose")
      eq(1, status)
      eq("error: unknown option '--verbose'\n" .. USAGE, stderr)
      status, stdout, stderr = willow(dir, "test a b")
      eq(1, status)
      eq("error: unexpected argument 'b'\n" .. USAGE, stderr)
    end)
  end,

  listing_example = function()
    in_temp_dir(function(dir)
      os.execute("cd " .. quote(dir) .. " && mkdir notes && printf hello > a.txt && ln -s a.txt link"
        .. " && TZ=UTC touch -t 202401020304.05 a.txt notes && TZ=UTC touch -h -t 202401020304.05 link")
      local status, stdout, stderr = sh(dir, "LISTING_DIR=. " .. quote(WILLOW) .. " run "
        .. quote(ROOT .. "/tests/fixtures/listing.wlo"))
      eq(0, status)
      eq("", stderr)
      local lines = {}
      for line in stdout:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
      end
      eq(9, #lines)
      eq("name            kind          size  modified", lines[1])
      eq("a.txt           file             5  2024-01-02T03:04:05Z", lines[2])
      eq("link            symlink          5  2024-01-02T03:04:05Z", lines[3])
      assert(lines[4]:match("^notes           directory +%d+  2024%-01%-02T03:04:05Z$"), lines[4])
      eq("", lines[5])
      assert(lines[6]:match("^directory    1 entries +%d+ bytes$"), lines[6])
      eq("file         1 entries         5 bytes", lines[7])
      eq("symlink      1 entries         5 bytes", lines[8])
      assert(lines[9]:match("^listed %. in %d+%.%d%d%ds$"), lines[9])

      write(dir .. "/link.wlo", "import fs\ndef main():\n"
        .. "    print(fs.stat('link').kind + ' ' + fs.stat('link', follow_symlinks=False).kind)\n")
      status, stdout = willow(dir, "run link.wlo")
      eq(0, status)
      eq("file symlink\n", stdout)
    end)
  end,

  broken_pipes_are_errors = function()
    in_temp_dir(function(dir)
      write(dir .. "/lines.wlo", "def main():\n    for i in range(100000):\n        print(i)\n")
      write(dir .. "/handle.wlo", table.concat({
        "import io",
        "import sys",
        "def main():",
        "    out = io.stdout()",
        "    try:",
        "        for i in range(100000):",
        "            out.write_text(f'{i}\\n')",
        "            out.flush()",
        "    except OSError as error:",
        "        sys.eprint('caught: ' + error.message)",
        "",
      }, "\n"))
      local status, stdout, stderr = sh(dir, "{ (" .. quote(WILLOW) .. " run lines.wlo; echo \"status $?\" >&2) | head -n 1; }")
      eq("0\n", stdout)
      eq("lines.wlo:3:9: error: cannot write output: Broken pipe\n  in main at lines.wlo:3:9\nstatus 1\n", stderr)
      status, stdout, stderr = sh(dir, "{ (" .. quote(WILLOW) .. " run handle.wlo; echo \"status $?\" >&2) | head -n 1; }")
      eq("0\n", stdout)
      -- Whether data is left to flush at exit after the failed write depends on
      -- the C library, so only the caught error is compared.
      eq("caught: cannot write <stdout>: Broken pipe\n", stderr:match("^[^\n]*\n"))
    end)
  end,

  copy_example = function()
    in_temp_dir(function(dir)
      local all = {}
      for i = 0, 255 do
        all[#all + 1] = string.char(i)
      end
      write(dir .. "/source.bin", table.concat(all):rep(300))
      local program = quote(ROOT .. "/tests/fixtures/copy.wlo")
      local status, stdout = willow(dir, "run " .. program .. " source.bin target.bin")
      eq(0, status)
      eq("copied 76800 bytes\n", stdout)
      eq(read(dir .. "/source.bin"), read(dir .. "/target.bin"))
      local stderr
      status, stdout, stderr = willow(dir, "run " .. program .. " missing.bin target.bin")
      eq(1, status)
      eq("cannot open missing.bin: No such file or directory\n", stderr)
    end)
  end,

  jsonl_example = function()
    in_temp_dir(function(dir)
      write(dir .. "/log.jsonl", '{"level": "info", "n": 1}\n{"level": "error", "n": 2}\n[1]\n{"level": "error", "n": 3}\n')
      local program = quote(ROOT .. "/tests/fixtures/jsonl.wlo")
      local status, stdout, stderr = willow(dir, "run " .. program .. " level error <log.jsonl")
      eq(0, status)
      eq('{"level": "error", "n": 2}\n{"level": "error", "n": 3}\n', stdout)
      eq("kept 2 of 4 records\n", stderr)
      status, stdout = willow(dir, "run " .. program .. " n 1 <log.jsonl")
      eq('{"level": "info", "n": 1}\n', stdout)
      write(dir .. "/bad.jsonl", '{"n": 1}\nnope\n')
      status, stdout, stderr = willow(dir, "run " .. program .. " n 1 <bad.jsonl")
      eq(1, status)
      eq('{"n": 1}\n', stdout)
      eq("line 2: expected 'null' at line 1, column 2\n", stderr)
    end)
  end,

  wrap_example = function()
    in_temp_dir(function(dir)
      local program = quote(ROOT .. "/tests/fixtures/wrap.wlo")
      local function wrap(args)
        return willow(dir, "run " .. program .. " " .. args)
      end
      local status, stdout = wrap("5 printf 'a b\\n'")
      eq(0, status)
      eq("status 0\nstdout: a b\nstderr: (empty)\n", stdout)
      status, stdout = wrap("5 printf '\\377\\000'")
      eq("status 0\nstdout: 2 bytes, not UTF-8\nstderr: (empty)\n", stdout)
      status, stdout = wrap("5 sh -c 'echo oops >&2; exit 4'")
      eq(1, status)
      eq("status 4\nstdout: (empty)\nstderr: oops\n", stdout)
      status, stdout = wrap("5 sh -c 'cat; echo $LC_ALL'")
      eq("status 0\nstdout: C\nstderr: (empty)\n", stdout)
      status, stdout = wrap("0.2 sleep 5")
      eq(1, status)
      eq("timed out: command timed out after 0.2 seconds\n", stdout)
      status, stdout = wrap("1 nosuchprogram")
      eq("failed: cannot run nosuchprogram: No such file or directory\n", stdout)
    end)
  end,

  calc_example = function()
    in_temp_dir(function(dir)
      local status, stdout = sh(dir, "printf '2 * (3 + 4)\\n-(1 - 3) / 4\\n\\n1 / 0\\n(1 + 2\\n3 $ 4\\n' | "
        .. quote(WILLOW) .. " run " .. quote(ROOT .. "/tests/fixtures/calc.wlo"))
      eq(0, status)
      eq("14.0\n0.5\ndivision by zero\ncolumn 7: expected ')'\ncolumn 3: unexpected '$'\n", stdout)
    end)
  end,

  trash_example = function()
    in_temp_dir(function(dir)
      os.execute("cd " .. quote(dir) .. " && mkdir sub && printf a > a.txt && printf b > sub/b.txt")
      local program = quote(ROOT .. "/tests/fixtures/trash.wlo")
      local status, stdout, stderr = willow(dir, "run " .. program .. " a.txt sub/b.txt sub missing")
      eq(1, status)
      eq("trash: sub is a directory\ntrash: cannot stat missing: No such file or directory\n", stderr)
      eq("a", read(dir .. "/.trash/a.txt"))
      eq("b", read(dir .. "/sub/.trash/b.txt"))
      assert(read(dir .. "/sub/.trash.log"):match("^%d+%-%d+%-%d+T%d+:%d+:%d+Z b%.txt\n$"))
      status, stdout = willow(dir, "run " .. program .. " --empty . sub")
      eq(0, status)
      eq(".: deleted 1 files\nsub: deleted 1 files\n", stdout)
      eq(nil, read(dir .. "/.trash/a.txt"))
    end)
  end,

  jobs_example = function()
    in_temp_dir(function(dir)
      local status, stdout = willow(dir, "run " .. quote(ROOT .. "/tests/fixtures/jobs.wlo")
        .. [[ --limit 1 logs 'echo job $JOB_NUMBER; cat' 'sleep 0.3; echo oops >&2; exit 3' 'exec sleep 5']])
      eq(1, status)
      eq("job 1: exit status 0: echo job $JOB_NUMBER; cat\njob 2: exit status 3: sleep 0.3; echo oops >&2; exit 3\n"
        .. "job 3: killed by signal 9: exec sleep 5\n", stdout)
      eq("job 1\n", read(dir .. "/logs/1.log"))
      eq("oops\n", read(dir .. "/logs/2.log"))
    end)
  end,

  report_example = function()
    in_temp_dir(function(dir)
      local lines = {}
      for i = 1, 2500 do
        lines[i] = i % 5 == 0 and "ERROR failed" or (i % 2 == 0 and "INFO ok" or "WARN slow")
      end
      write(dir .. "/app.log", table.concat(lines, "\n") .. "\n")
      local program = quote(ROOT .. "/tests/fixtures/report.wlo")
      local status, stdout, stderr = willow(dir, "run " .. program .. " --help")
      eq(0, status)
      eq("usage: report [options] [file ...]\n", stdout:match("^[^\n]*\n"))
      status, stdout, stderr = willow(dir, "run " .. program .. " --limit")
      eq(2, status)
      eq("usage: report [options] [file ...]\nreport: error: option '--limit' needs a value\n", stderr)
      eq(2, (willow(dir, "run " .. program .. " -n -1 app.log")))
      -- Piped output is plain and progress stays off a non-terminal stderr.
      local table_text = "level        lines\nINFO          1000\nWARN          1000\nERROR          500\ntotal         2500\n"
      status, stdout, stderr = willow(dir, "run " .. program .. " app.log")
      eq(0, status)
      eq(table_text, stdout)
      eq("", stderr)
      status, stdout = willow(dir, "run " .. program .. " -n 1 --sort=name < app.log")
      eq("level        lines\nERROR          500\ntotal         2500\n", stdout)
      -- On a terminal the table is styled and progress lines are replaced.
      local output = in_terminal(dir, "env -u NO_COLOR TERM=xterm " .. quote(WILLOW) .. " run " .. program .. " app.log")
      eq("\r\27[Kread 1000 lines\r\27[Kread 2000 lines\r\27[K\27[1mlevel        lines\27[0m\n"
        .. "\27[32mINFO      \27[0m    1000\n\27[33mWARN      \27[0m    1000\n\27[31mERROR     \27[0m     500\n"
        .. "total         2500\n", output)
      output = in_terminal(dir, "TERM=dumb " .. quote(WILLOW) .. " run " .. program .. " --color=never -q app.log")
      eq(table_text, output)
    end)
  end,

  finish_progress_message = function()
    in_temp_dir(function(dir)
      write(dir .. "/done.wlo", "import terminal\ndef main():\n    terminal.progress('x')\n    terminal.finish_progress('done')\n")
      local status, stdout, stderr = willow(dir, "run done.wlo")
      eq(0, status)
      eq("", stdout)
      eq("done\n", stderr)
      eq("\r\27[Kx\r\27[Kdone\n", in_terminal(dir, "TERM=xterm " .. quote(WILLOW) .. " run done.wlo"))
    end)
  end,

  http_client = function()
    with_http_server(function(base, port)
      in_temp_dir(function(dir)
        local status, stdout, stderr = willow(dir, "run " .. quote(ROOT .. "/tests/http/client.wlo") .. " "
          .. base .. " " .. quote(dir))
        eq("", stderr)
        eq(0, status)
        eq(read(ROOT .. "/tests/http/client.out"), (stdout:gsub(port, "PORT")))
      end)
    end)
  end,

  api_and_fetch = function()
    with_http_server(function(base)
      in_temp_dir(function(dir)
        local api, fetch = quote(ROOT .. "/tests/fixtures/api.wlo"), quote(ROOT .. "/tests/fixtures/fetch.wlo")
        local status, stdout = willow(dir, "run " .. api .. " " .. base .. "/json")
        eq(0, status)
        eq('status 200\nname: "Willow"\nports: [80,443]\n', stdout)
        status, stdout = willow(dir, "run " .. api .. " " .. base .. "/echo '{\"x\": [1, 2]}'")
        eq(0, status)
        assert(stdout:find('method: "POST"\n', 1, true) and stdout:find('body: "{\\"x\\":[1,2]}"\n', 1, true), stdout)
        status = willow(dir, "run " .. api .. " " .. base .. "/status/404")
        eq(1, status)
        status, stdout = willow(dir, "run " .. fetch .. " " .. base .. "/redirect/1 out.bin")
        eq(0, status)
        eq("saved 4 bytes from " .. base .. "/redirect/0 to out.bin\n", stdout)
        eq("done", read(dir .. "/out.bin"))
        status = willow(dir, "run " .. fetch .. " " .. base .. "/echo echo.json 'q=tea time'")
        eq(0, status)
        assert(read(dir .. "/echo.json"):find('"path": "/echo?q=tea+time"', 1, true), read(dir .. "/echo.json"))
        status, stdout = willow(dir, "run " .. fetch .. " " .. base .. "/status/404 out.bin")
        eq(1, status)
        eq("HTTP 404 from " .. base .. "/status/404; out.bin left unchanged\n", stdout)
        eq("done", read(dir .. "/out.bin"))
      end)
    end)
  end,

  https_client = function()
    if os.execute("command -v openssl >/dev/null 2>&1") ~= 0 then
      return
    end
    in_temp_dir(function(dir)
      local made = os.execute("cd " .. quote(dir) .. " && openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem"
        .. " -out cert.pem -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1")
      assert(made == 0, "cannot make a certificate")
      write(dir .. "/hello.txt", "secure hello")
      local port = tostring(20000 + os.time() % 20000)
      local pid = start_server("cd " .. quote(dir) .. " && exec openssl s_server -quiet -accept " .. port
        .. " -cert cert.pem -key key.pem -WWW", dir .. "/server.log")
      write(dir .. "/tls.wlo", table.concat({
        "import http",
        "import sys",
        "def attempt(url: str, ca_file: str | None):",
        "    try:",
        "        r = http.request('GET', url, ca_file=ca_file, timeout=5.0)",
        "        print(f'{r.status} {r.body.decode()}')",
        "    except OSError as error:",
        "        print('failed: ' + error.message.split(': ')[0])",
        "def main():",
        "    port = sys.args()[0]",
        "    attempt('https://localhost:' + port + '/hello.txt', 'cert.pem')",
        "    attempt('https://localhost:' + port + '/hello.txt', None)",
        "    attempt('https://127.0.0.1:' + port + '/hello.txt', 'cert.pem')",
        "",
      }, "\n"))
      local ok, err = pcall(function()
        local stdout
        for _ = 1, 50 do
          local _, out = willow(dir, "run tls.wlo " .. port)
          stdout = out
          if stdout:match("^200") then
            break
          end
          os.execute("sleep 0.1")
        end
        eq("200 secure hello\nfailed: cannot fetch https://localhost:" .. port .. "/hello.txt\n"
          .. "failed: cannot fetch https://127.0.0.1:" .. port .. "/hello.txt\n", stdout)
      end)
      os.execute("kill " .. pid .. " 2>/dev/null")
      if not ok then
        error(err, 0)
      end
    end)
  end,

  kv_example = function()
    local status, stdout, stderr = willow(ROOT, "test tests/fixtures/kv")
    eq("", stderr)
    eq(0, status)
    eq("PASS tests/fixtures/kv/test_kv.wlo test_clients_are_served_in_turn\n"
      .. "PASS tests/fixtures/kv/test_kv.wlo test_set_get_and_keys\n"
      .. "PASS tests/fixtures/kv/test_kv.wlo test_split_code_point_is_reassembled\n3 passed, 0 failed\n", stdout)
    in_temp_dir(function(dir)
      local pid = start_server(quote(WILLOW) .. " run " .. quote(ROOT .. "/tests/fixtures/kv/server.wlo") .. " "
        .. quote(dir .. "/port"), dir .. "/server.log")
      local port
      for _ = 1, 100 do
        port = read(dir .. "/port")
        if port then
          break
        end
        os.execute("sleep 0.05")
      end
      local ok, err = pcall(function()
        local client = quote(ROOT .. "/tests/fixtures/kv/client.wlo")
        local code, out = willow(dir, "run " .. client .. " " .. assert(port, "server did not start")
          .. [[ '{"op": "set", "key": "a", "value": 1}' '{"op": "get", "key": "a"}' '{"op": "shutdown"}']])
        eq(0, code)
        eq('{"ok":true}\n{"value":1}\n{"ok":true}\n', out)
      end)
      os.execute("kill " .. pid .. " 2>/dev/null")
      if not ok then
        error(err, 0)
      end
    end)
  end,

  project_commands = function()
    in_temp_dir(function(dir, base)
      os.execute("cd " .. quote(dir) .. " && mkdir -p src/app vendor/textkit vendor2/textkit tests/unit empty")
      write(dir .. "/willow.json", '{"entry": "app/main.wlo", "source": "src", "dependencies": ["vendor"]}')
      write(dir .. "/src/app/main.wlo", table.concat({
        "import app.greet",
        "import sys",
        "def main():",
        "    names = sys.args()",
        "    if len(names) == 0:",
        "        names = ['world']",
        "    for name in names:",
        "        print(app.greet.greet(name))",
        "",
      }, "\n"))
      -- The entry is registered under its own name, so this imports it.
      write(dir .. "/src/app/greet.wlo", "import app.main\nimport textkit.shout\n"
        .. "def greet(name: str) -> str:\n    return textkit.shout.shout('hello, ' + name)\n")
      write(dir .. "/vendor/textkit/shout.wlo", "def shout(text: str) -> str:\n    return text.upper() + '!'\n")
      write(dir .. "/tests/test_shout.wlo", "import textkit.shout\n"
        .. "def test_shout():\n    assert textkit.shout.shout('a') == 'A!'\n")
      write(dir .. "/tests/unit/test_greet.wlo", "import app.greet\n"
        .. "def test_greet():\n    assert app.greet.greet('x') == 'HELLO, X!'\n")

      local status, stdout, stderr = willow(dir, "check")
      eq(0, status)
      eq("", stderr)
      status, stdout = willow(dir, "run")
      eq("HELLO, WORLD!\n", stdout)
      status, stdout = willow(dir, "run -- Ada --verbose")
      eq("HELLO, ADA!\nHELLO, --VERBOSE!\n", stdout)
      eq(0, willow(dir, "compile -o out.lua"))
      eq(0, willow(dir, "build -o app.bin"))
      status, stdout = sh(base, quote(LUAJIT) .. " " .. quote(dir .. "/out.lua") .. " Lua")
      eq("HELLO, LUA!\n", stdout)
      status, stdout = sh(base, quote(dir .. "/app.bin") .. " Bin")
      eq("HELLO, BIN!\n", stdout)

      status, stdout = willow(dir, "test")
      eq(0, status)
      eq("PASS tests/test_shout.wlo test_shout\nPASS tests/unit/test_greet.wlo test_greet\n2 passed, 0 failed\n", stdout)
      status, stdout = willow(dir, "test tests/unit")
      eq("PASS tests/unit/test_greet.wlo test_greet\n1 passed, 0 failed\n", stdout)
      status, stdout, stderr = willow(dir, "test --check")
      eq(0, status)
      eq("", stdout .. stderr)

      -- An explicit file keeps the file workflow and ignores the manifest.
      status, stdout, stderr = willow(dir, "check src/app/main.wlo")
      eq(1, status)
      eq("src/app/main.wlo:1:8: error: cannot load module 'app.greet': src/app/app/greet.wlo: No such file or directory\n", stderr)
      status, stdout, stderr = willow(dir .. "/empty", "check")
      eq(1, status)
      eq("error: no source file given and no willow.json in the current directory\n", stderr)

      local function manifest_error(text)
        write(dir .. "/willow.json", text)
        local code, _, err = willow(dir, "check")
        eq(1, code)
        return err
      end
      eq("error: willow.json: unknown key 'name'\n", manifest_error('{"name": "x"}'))
      eq("error: willow.json: 'source' must be a string\n", manifest_error('{"source": 1}'))
      eq("error: willow.json: 'dependencies' must be a list of strings\n", manifest_error('{"dependencies": "vendor"}'))
      eq("error: willow.json: 'dependencies' must be a list of strings\n", manifest_error('{"dependencies": null}'))
      eq("error: willow.json: expected ',' or ']' at line 1, column 20\n", manifest_error('{"dependencies": [1-2]}'))
      eq("error: willow.json: expected an object\n", manifest_error('[]'))
      eq("error: willow.json: expected an object\n", manifest_error('false'))
      eq("error: willow.json: expected an object\n", manifest_error('null'))
      eq("error: willow.json: expected value at line 1, column 11\n", manifest_error('{"entry": }'))
      local entry_message = "error: willow.json: 'entry' must be a .wlo path inside the source root with identifier components\n"
      eq(entry_message, manifest_error('{"entry": "../main.wlo"}'))
      eq(entry_message, manifest_error('{"entry": "main.py"}'))
      eq(entry_message, manifest_error('{"entry": "my-app/main.wlo"}'))

      write(dir .. "/vendor2/textkit/shout.wlo", "def shout(text: str) -> str:\n    return text\n")
      eq("src/app/greet.wlo:2:8: error: module 'textkit.shout' is ambiguous: found in vendor/textkit/shout.wlo"
        .. " and vendor2/textkit/shout.wlo\n",
        manifest_error('{"entry": "app/main.wlo", "source": "src", "dependencies": ["vendor", "vendor2"]}'))
      write(dir .. "/src/app/main.wlo", "import app.greet\nimport greet\ndef main():\n    pass\n")
      eq("src/app/main.wlo:2:8: error: module 'greet' is the same file as module 'app.greet'\n",
        manifest_error('{"entry": "app/main.wlo", "source": "src", "dependencies": ["vendor", "src/app"]}'))
      write(dir .. "/src/app/main.wlo", "import textkit.shout\ndef main():\n    pass\n")
      write(dir .. "/vendor/textkit/shout.wlo", "import textkit.missing\n")
      eq("vendor/textkit/shout.wlo:1:8: error: cannot load module 'textkit.missing': src/textkit/missing.wlo: No such file or directory\n",
        manifest_error('{"entry": "app/main.wlo", "source": "src", "dependencies": ["vendor"]}'))
    end)
  end,

  init_command = function()
    in_temp_dir(function(dir)
      local status, stdout, stderr = willow(dir, "init")
      eq("", stderr)
      eq(0, status)
      eq("created willow.json\ncreated src/main.wlo\ncreated tests/test_main.wlo\ncreated AGENTS.md\n"
        .. "created .gitignore\ninitialized a git repository\n", stdout)
      eq("/with space\n/with space.lua\n", read(dir .. "/.gitignore"))
      status, stdout = willow(dir, "run")
      eq(0, status)
      eq("Hello, Willow!\n", stdout)
      status, stdout = willow(dir, "test")
      eq(0, status)
      eq("PASS tests/test_main.wlo test_main_runs\n1 passed, 0 failed\n", stdout)
      status, stdout = sh(dir, "git status --short")
      eq(0, status)
      eq("?? .gitignore\n?? AGENTS.md\n?? src/\n?? tests/\n?? willow.json\n", stdout)
      status, stdout, stderr = willow(dir, "init")
      eq(1, status)
      eq("error: willow.json already exists\n", stderr)
      status, _, stderr = willow(dir, "init extra")
      eq(1, status)
      eq("error: unexpected argument 'extra'\n" .. USAGE, stderr)
    end)
  end,

  portcheck_example = function()
    local project = ROOT .. "/tests/fixtures/portcheck"
    local status, stdout, stderr = willow(project, "test")
    eq("", stderr)
    eq(0, status)
    eq("4 passed, 0 failed\n", stdout:match("[^\n]*\n$"))
    in_temp_dir(function(dir, base)
      eq(0, willow(project, "build -o " .. quote(dir .. "/portcheck")))
      status, stdout = sh(base, quote(dir .. "/portcheck") .. " --timeout 1 127.0.0.1:1")
      eq(1, status)
      assert(stdout:match("^target       state   time\n127%.0%.0%.1:1  closed  [%d.]+ ms\n$"), stdout)
      status, stdout = sh(base, quote(dir .. "/portcheck") .. " --json 127.0.0.1:1")
      eq('{"target":"127.0.0.1:1","open":false,"detail":"cannot connect to 127.0.0.1:1: Connection refused"}\n', stdout)
      local _, _, err = sh(base, quote(dir .. "/portcheck") .. " nope")
      eq("portcheck: error: expected host:port, received 'nope'\n", err)
    end)
  end,

  qualified_entry_call = function()
    in_temp_dir(function(dir)
      write(dir .. "/prog.wlo", table.concat({
        "import prog",
        "def f() -> int:",
        "    return 7",
        "def main():",
        "    f = 1",
        "    print(prog.f())",
        "",
      }, "\n"))
      local status, stdout, stderr = willow(dir, "run prog.wlo")
      eq("", stderr)
      eq(0, status)
      eq("7\n", stdout)
    end)
  end,

  combined_optional_runtimes = function()
    in_temp_dir(function(dir)
      local source = table.concat({
        "import fs",
        "import io",
        "import cli",
        "import http",
        "import json",
        "def exercise():",
        "    assert fs.join('a', 'b') == 'a/b'",
        "    io.stdout().flush()",
        "    parser = cli.parser('mixed')",
        "    parser.add_str('name', 'default')",
        "    args = parser.parse(['--name', 'Willow'])",
        "    assert args.get_str('name') == 'Willow'",
        "    assert 'mixed' in parser.help()",
        "    assert http.urlencode({'x': 'a b'}) == 'x=a+b'",
        "    assert json.dump(json.parse('[1,2.5]')) == '[1,2.5]'",
        "    assert bytes([195, 169]).decode().upper() == 'É'",
        "",
      }, "\n")
      write(dir .. "/prog.wlo", source .. "def main():\n    exercise()\n    print('ok')\n")
      local status, stdout, stderr = willow(dir, "run prog.wlo")
      eq("", stderr)
      eq(0, status)
      eq("ok\n", stdout)
      eq(0, willow(dir, "compile prog.wlo -o out.lua"))
      status, stdout, stderr = sh(dir, quote(LUAJIT) .. " out.lua")
      eq("", stderr)
      eq(0, status)
      eq("ok\n", stdout)
      eq(0, willow(dir, "build prog.wlo -o out"))
      status, stdout, stderr = sh(dir, "./out")
      eq("", stderr)
      eq(0, status)
      eq("ok\n", stdout)
      write(dir .. "/test_mixed.wlo", source .. "def test_mixed():\n    exercise()\n")
      status, stdout, stderr = willow(dir, "test test_mixed.wlo")
      eq("", stderr)
      eq(0, status)
      eq("PASS test_mixed.wlo test_mixed\n1 passed, 0 failed\n", stdout)
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
