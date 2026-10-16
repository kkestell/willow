local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local lower = require("compiler.lower")
local emit = require("compiler.emit")

local function eq(expected, actual)
  if expected ~= actual then
    error(string.format("expected %q, got %q", tostring(expected), tostring(actual)), 2)
  end
end

local function emit_source(source)
  local program = parser.parse(lexer.lex(source, "test.wlo"))
  bind.bind({ program })
  check.check({ program })
  return emit.emit(lower.lower({ program }))
end

local willow = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/willow"

-- Runs `source` through the launcher with `redirect` applied to stdout;
-- returns the exit status, stderr, and the path the program was written to.
local function run(source, redirect)
  local base = os.tmpname()
  local path, err_path = base .. ".wlo", base .. ".err"
  local file = assert(io.open(path, "wb"))
  file:write(source)
  file:close()
  local shell = io.popen(string.format("%s run %s %s 2>%s; echo $?", willow, path, redirect, err_path))
  local status = shell:read("*n")
  shell:close()
  file = assert(io.open(err_path, "rb"))
  local stderr = file:read("*a")
  file:close()
  os.remove(base)
  os.remove(path)
  os.remove(err_path)
  return status, stderr, path
end

return {
  quote_round_trips = function()
    for _, s in ipairs({ "\\ ' \" \n \r \t", "\0" .. "1", "\1\31\127", "日本語 ✓ café", "" }) do
      eq(s, load("return " .. emit.quote(s))())
    end
  end,

  mangle_is_one_to_one = function()
    eq("end_", emit.mangle("end"))
    eq("nil_", emit.mangle("nil"))
    eq("x__", emit.mangle("x_"))
    eq("__wlo_t1_", emit.mangle("__wlo_t1"))
    eq("total", emit.mangle("total"))
    eq("x", emit.mangle("x"))
    assert(emit.mangle("end") ~= emit.mangle("end_"))
  end,

  output_is_deterministic = function()
    local source = "def f(n: int) -> int:\n    return n * 2\ndef main() -> None:\n    print(f(1) + f(2))\n"
    local first = emit_source(source)
    eq(first, emit_source(source))
    eq(nil, first:find("0x", 1, true))
  end,

  case_runtime_only_when_used = function()
    eq(nil, emit_source("def main() -> None:\n    print('a'.strip())\n"):find("__wlo_LOWER_RUNS", 1, true))
    assert(emit_source("def main() -> None:\n    print('a'.upper())\n"):find("__wlo_LOWER_RUNS", 1, true))
  end,

  one_call_per_line = function()
    local text = emit_source(table.concat({
      "def f(a: int, b: int) -> int:",
      "    return a * b + f(a - 1, b) - -a",
      "def main() -> None:",
      "    x = f(f(1, 2) + f(3, 4), f(5, f(6, 7)))",
      "    print(f(x, 1) == 2 and f(1, 1) < 3)",
    }, "\n"))
    local section = text:match("\nlocal f, main\n(.-)\n__wlo_sites = ")
    assert(section, "function section not found")
    for line in section:gmatch("[^\n]+") do
      if not line:match("^function ") then
        local _, calls = line:gsub("[%w_]+%(", "")
        assert(calls <= 1, "more than one call on line: " .. line)
      end
    end
  end,

  write_failures_are_runtime_errors = function()
    local status, stderr, path = run("def main() -> None:\n    print(1)\n", ">&-")
    eq(1, status)
    assert(stderr:find(path .. ":2:5: error: cannot write output: ", 1, true) == 1, stderr)
    assert(stderr:find("\n  in main at " .. path .. ":2:5\n", 1, true), stderr)
  end,

  stack_overflow_reports_innermost_frame = function()
    local status, stderr, path = run("def down(n: int) -> int:\n    return down(n + 1)\ndef main() -> None:\n    print(down(0))\n", "")
    eq(1, status)
    assert(stderr:find(path .. ":1:5: error: stack overflow\n  in down at " .. path .. ":1:5\n", 1, true) == 1, stderr)
    local _, lines = stderr:gsub("\n", "")
    eq(22, lines)
    assert(stderr:match("\n  %.%.%. %d+ more frames\n$"), stderr)
  end,
}
