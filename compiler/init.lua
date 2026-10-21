-- `willow init`: scaffolds a project in the current directory.
local ffi = require("ffi")
local loader = require("compiler.loader")
local quote = require("compiler.runner").quote

ffi.cdef([[char *getcwd(char *buffer, size_t size);]])

local M = {}

local MANIFEST = [[
{
  "entry": "main.wlo",
  "source": "src",
  "tests": "tests"
}
]]

local MAIN = [[
def main() -> None:
    print("Hello, Willow!")
]]

local TEST = [[
import main

def test_main_runs() -> None:
    main.main()
]]

local GITIGNORE = [[
/@NAME@
/@NAME@.lua
]]

local AGENTS = [==[
# @NAME@

This project is written in Willow, a small, statically typed language with
Python-like syntax that compiles to Lua and runs on LuaJIT. Source files use
the `.wlo` extension. The `willow` command is on the `PATH`.

## Layout

- `willow.json` describes the project: the entry file `main.wlo` under the
  source root `src`, and the test directory `tests`.
- `src/` holds the program's modules. `import app.util` loads `src/app/util.wlo`.
- `tests/` holds test files named `test_*.wlo`.

## Commands

Run these from the project root. They read `willow.json`.

```sh
willow check                     # check the whole program without running it
willow run -- arg1 arg2          # check and run; the arguments go to sys.args()
willow test                      # run every test_*.wlo under tests/
willow test --check              # check the tests without running them
willow test tests/test_main.wlo  # run one test file
willow build -o @NAME@           # build a standalone executable
willow compile -o @NAME@.lua     # write the program as one Lua file for luajit
```

Errors are written to stderr as `file:line:column: error: message`. The exit
status is 0 on success and 1 for usage errors, source errors, and runtime
errors. An uncaught exception reports its class, message, and call frames.

## Language

A file contains `import` statements followed by `def`, `async def`, `class`,
`enum`, `type`, and `protocol` declarations. The entry file defines
`def main() -> None:`. Blocks are indented with four spaces, and comments start
with `#`. The whole program is type-checked before any of it runs.

```python
import sys

enum Level:
    LOW
    HIGH

class Reading:
    name: str
    value: float
    level: Level = Level.LOW

class ParseError(Exception):
    line: int

def parse(line: str, number: int) -> Reading:
    parts = line.split(",")
    if len(parts) != 2:
        raise ParseError("expected name,value", number)
    value = float(parts[1].strip())
    reading = Reading(parts[0].strip(), value)
    if value > 100.0:
        reading.level = Level.HIGH
    return reading

def summarize(readings: list[Reading]) -> dict[str, float]:
    totals: dict[str, float] = {}
    for reading in readings:
        previous = totals.get(reading.name)
        if previous is None:
            previous = 0.0
        totals[reading.name] = previous + reading.value
    return totals

def main() -> None:
    readings: list[Reading] = []
    number = 0
    for line in sys.args():
        number = number + 1
        try:
            readings.append(parse(line, number))
        except ParseError as error:
            sys.eprint(f"argument {error.line}: {error.message}")
            sys.exit(1)
    totals = summarize(readings)
    for name in totals:
        print(f"{name:<10}{totals[name]:>8.1f}")
```

Rules that differ from Python:

- Every parameter and return type is annotated. Types are `int`, `float`,
  `bool`, `str`, `bytes`, `None`, `list[T]`, `dict[K, V]`, `tuple[A, B]`,
  unions such as `int | None`, function types such as `(int) -> str`, classes,
  enums, and protocols. Generic functions and classes take type parameters:
  `def first[T](items: list[T]) -> T | None:`.
- A local variable takes the type of its first assignment. Annotate it when
  the value does not determine the type: `rows: list[str] = []`,
  `best: str | None = None`.
- Conditions must be `bool`. `if count:` and `if name:` are type errors.
- `==` and `!=` compare scalars only. Lists, dictionaries, and class values
  cannot be compared with `==`.
- `is None` and `is not None` narrow optional locals. Fields are not narrowed,
  so copy a field to a local before testing it.
- Integers are exact from `-(2^53 - 1)` through `2^53 - 1`. `/` always gives a
  `float`; `//` and `%` keep the operand type. Both operands of an arithmetic
  operator have the same type; convert with `int(x)` and `float(n)`.
- `+=`, `**`, bitwise operators, chained comparisons, conditional expressions,
  and `x = y = 0` are not supported.
- Strings are immutable code-point sequences with `len`, indexing, slicing,
  `in`, `startswith`, `endswith`, `find`, `replace`, `strip`, `split`, `lower`,
  `upper`, `ljust`, `rjust`, and `sep.join(items)`. f-strings accept format
  specifications such as `{value:>8.2f}`.
- Lists have `append`, `pop`, `sort`, indexing, slicing, and `in`.
  Dictionaries keep insertion order and have `get`, `pop`, indexing, and `in`.
  Dictionary keys are `int`, `str`, or an enum. `sorted(items, key=...)`
  returns a new list.
- A class body lists fields, then methods. Calling the class constructs a value
  with one argument per field, positional or by keyword, and fields may have
  defaults. Methods take `self` first. Classes have no inheritance, except that
  exception classes are declared with `class Name(Exception):` and gain a
  `message: str` field before their own fields.
- `raise` takes an exception value. `try` has `except Class as name` clauses
  and an optional `finally`. The built-in exceptions include `ValueError`,
  `IndexError`, `KeyError`, `OSError`, `RuntimeError`, and `AssertionError`.
- `import a.b` loads `a/b.wlo` from `src/`, a dependency root, or the standard
  library, and its declarations are used by full name: `a.b.func()`. Names that
  begin with `_` are private to their module.
- Built-in functions: `print`, `input`, `len`, `range`, `int`, `float`, `str`,
  `bytes`, `ord`, `chr`, `isinstance`, `sorted`, `iter`, and `next`.
- Also available: nested functions and `nonlocal`, lambdas, generators with
  `yield` returning `Iterator[T]`, `with` for values that have `enter` and
  `exit` methods, and `async def`, `await`, and `async with aio.task_group()`
  for concurrency.

## Standard library

| Module | Provides |
| --- | --- |
| `sys` | `args()`, `eprint(value)`, `exit(status)`, `getenv(name)`, `environ()`, `getcwd()` |
| `fs` | `read_file`, `write_file`, `exists`, `listdir`, `stat`, `mkdir`, `remove`, `rename`, `join`, `basename`, `dirname` |
| `io` | `open(path, mode)` returning a `File` with `read`, `readline`, `write`, `write_text`, `close`; `stdin()`, `stdout()`, `stderr()` |
| `json` | `parse(text)` and `dump(value)` over the `json.Json` type |
| `cli` | `parser(prog)` with `add_str`, `add_int`, `add_flag`, `add_positional`, `add_rest`, and `parse(args)` |
| `subprocess` | `run(args, capture_output=True)` returning a `Result` with `stdout`, `stderr`, and the exit status |
| `http` | `request(method, url, headers=..., body=...)` returning a `Response` with `status`, `headers`, and `body` |
| `net` | TCP `listen`, `connect`, and `accept` |
| `aio` | `sleep`, `task_group`, and async TCP |
| `time` | `time()`, `monotonic()`, `sleep(seconds)`, `utc(timestamp)` |
| `terminal` | `isatty`, `color_enabled`, `style`, `progress` |
| `math` | `sqrt` |

Library functions raise `OSError`, `ValueError`, or `TimeoutError` with a
`message` field when they fail.

## Testing

Test files are named `tests/test_*.wlo`. Their functions whose names begin with
`test_` take no parameters, return `None`, and pass when they return. Use
`assert condition, "message"` to check results. Imports in tests resolve from
`src/`, so `import main` loads `src/main.wlo`.

```python
import main

def test_main_runs() -> None:
    main.main()
```

Each test runs in a new process. The report lists `PASS` or `FAIL` for every
test and shows the output of failing tests.
]==]

local function fail(message)
  io.stderr:write(message, "\n")
  os.exit(1)
end

local function create(path, text)
  if loader.file_id(path) then
    return
  end
  local file, err = io.open(path, "wb")
  if not file then
    fail("error: cannot write " .. path .. ": " .. err)
  end
  file:write(text)
  file:close()
  print("created " .. path)
end

function M.init()
  if loader.file_id("willow.json") then
    fail("error: willow.json already exists")
  end
  local buffer = ffi.new("char[4096]")
  local cwd = ffi.string(ffi.C.getcwd(buffer, 4096))
  local name = cwd:match("([^/]+)/*$") or "app"
  local function fill(template)
    return (template:gsub("@NAME@", function()
      return name
    end))
  end
  for _, dir in ipairs({ "src", "tests" }) do
    if os.execute("mkdir -p " .. quote(dir)) ~= 0 then
      fail("error: cannot create directory " .. dir)
    end
  end
  create("willow.json", MANIFEST)
  create("src/main.wlo", MAIN)
  create("tests/test_main.wlo", TEST)
  create("AGENTS.md", fill(AGENTS))
  create(".gitignore", fill(GITIGNORE))
  if not loader.file_id(".git") then
    if os.execute("git init -q") ~= 0 then
      fail("error: git init failed")
    end
    print("initialized a git repository")
  end
end

return M
