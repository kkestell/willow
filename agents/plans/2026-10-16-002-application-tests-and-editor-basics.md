# Application tests and editor basics

## Goal

Implement `docs/spec.md` §17: `assert` statements raising `AssertionError`, a
`willow test [--check] [path]` command that checks every test module before
running each `test_*` function in its own process, and the `WILLOW` variable for
`run` and `test`. Ship basic VS Code support for `.wlo` files, with syntax
highlighting, four-space indentation, and check tasks. Deliver a multi-module
example app with passing tests, and a fixture with failing ones. Fold §17 into
the baseline spec.

## Related code

- `compiler/parser.lua` — `unsupported` lists `assert`; `parse_statement`.
- `compiler/bind.lua` — the built-in `exceptions` list; `M.bind` requires
  `main` in the entry module.
- `compiler/check.lua` — `check_condition`, `narrow`, `replace`, and the `If`
  branch of `check_statement`.
- `compiler/lower.lua` — `lower_statement`; `lower_short_circuit` shows how a
  branch body is lowered into its own `out`.
- `compiler/emit.lua` — the closing `__wlo_run(main, ...)` line.
- `runtime/core.lua` — `__wlo_fail` and `__wlo_run`.
- `compiler/cli.lua` — `parse_args`, `translate`, and the command dispatch.
- `willow` — the launcher script.
- `tests/unit/cli_test.lua` — `in_temp_dir`, `sh`, and `willow` helpers.

## Decisions

- **Assert syntax and checking.** `assert` leaves `unsupported`;
  `parse_statement` parses `assert condition` with an optional `, message` into
  an `Assert` node `{ condition, message }` at the keyword. Check gets the
  condition's facts with `check_condition`, checks the message against `str`
  under `narrow(state, false_facts)`, then applies the true facts with
  `replace(state, narrow(state, true_facts))`. `Assert` does not transfer
  control and is not in `assigned_symbols`.
- **Assert lowering.** Lowering evaluates the condition with `lower_operand`,
  lowers the message (or the literal `assertion failed`) into a separate body
  ending in `Eval` of the helper `assert_fail` at the statement's span, and
  emits `If` on `Not` of the condition. `__wlo_assert_fail(message, site)` calls
  `__wlo_fail("AssertionError", message, site)`. `AssertionError` joins the
  built-in `exceptions` in `bind`.
- **Test entries in bind.** `M.bind(modules, test)` skips the `main`
  requirement when `test` is true and instead sets `entry.tests` to the entry
  module's functions named `test_*`, sorted by name. Each must have no
  parameters and return `None`, or bind reports
  `test function 'test_x' must take no parameters and return None` at it.
- **Test chunks in emit.** When `lowered.modules[1].tests` is set, `emit` ends
  with a table of the tests by name (keys are the Willow names, values the
  mangled locals) and
  `local __wlo_name, __wlo_result = ...`,
  `__wlo_run(__wlo_tests[__wlo_name])`, and
  `io.open(__wlo_result, "wb"):close()` instead of `__wlo_run(main, ...)`.
  `__wlo_run` gets no arguments, so `sys.args()` is empty, and the result file
  exists only when the test returned: an exception exits through `__wlo_run`
  and `sys.exit` exits from its helper.
- **Runner module.** New `compiler/runner.lua` holds the test command; the CLI
  hands it `root`, the `--check` flag, and the path. `parse_args` recognizes
  `test`, at most one `--check`, and at most one path (default `.`).
  - `discover(path)`: when `test -d` succeeds for the path, list
    `find PATH -maxdepth 1 -type f -name 'test_*.wlo'` and sort the results;
    otherwise the path itself is the one file. A directory path `.` yields bare
    file names, other directories `dir/name`.
  - Checking: each file goes through `loader.load`, `bind.bind(modules, true)`,
    `check.check`, `lower.lower`, and `emit.emit`, with diagnostics formatted as
    the CLI does. Every file is checked; any errors are printed to stderr and
    the command exits 1 before running anything. Zero tests in total is
    `error: no tests found in PATH`, exit 1. `--check` stops here with exit 0
    and no output.
  - Running: each file's Lua goes to an `os.tmpname()` file; each test runs as
    `LUAJIT LUA NAME RESULT </dev/null 2>&1; printf '\n%d' $?` through
    `io.popen`, with the bundled LuaJIT, so its stdout and stderr are captured
    together, it inherits the working directory, and the trailing line gives its
    status. A test passes when its status is 0 and the result file exists.
  - Report on stdout: `PASS path test_name` or `FAIL path test_name` per test in
    order; after a failure, the captured output with each line indented two
    spaces, then `  exit status N`. The last line is `N passed, M failed`. The
    command exits 0 only when every test passed.
- **`WILLOW` variable.** The launcher exports `WILLOW="$root/willow"` before
  running the CLI, which covers `run` and `test` (and harmlessly `check`,
  `compile`, and `build`); compiled and built programs run without the
  launcher. No Willow program can read the environment until §18, so this has
  no automated test yet.
- **Editor support.** `editors/vscode/` is an unpackaged VS Code extension:
  `package.json` contributes the `willow` language for `.wlo`, its grammar, a
  `willow` problem matcher for `file:line:col: error: message`, and
  `[willow]` defaults of four spaces with indentation detection off;
  `language-configuration.json` sets `#` comments, brackets, auto-closing
  quotes, and indentation after a line ending in `:`;
  `syntaxes/willow.tmLanguage.json` highlights comments, strings and f-strings
  (with escapes and fields), numbers, keywords, built-in types and names,
  function and class names after `def` and `class`, and operators. The README
  shows how to link the extension and a `tasks.json` with
  `willow check ${file}` and `willow test --check ${file}` using the matcher.

## Test plan

- `tests/unit/parser_test.lua`: `assert x` and `assert x, "m"` shapes;
  `assert` without a condition rejected.
- `tests/unit/check_test.lua`: non-`bool` condition and non-`str` message
  rejected; `x + 1` accepted after `assert x is not None` for `x: int | None`;
  `assert isinstance(v, int), v` accepted for `v: int | str`, since the message
  sees `v` as `str`; `assert False` followed by a statement is not unreachable,
  and a non-`None` function ending in `assert False` still needs a return.
- `tests/programs/assertions.wlo`, `.out`, `.err`: a passing assertion with a
  message that would raise is not evaluated; a caught `AssertionError` with and
  without a message; an uncaught one reports
  `file:line:col: error: AssertionError: ...` with frames.
- `tests/unit/cli_test.lua`:
  - `willow test examples/cart` exits 0 with the exact report.
  - `willow test tests/suites/failing` exits 1 with the exact report: a passing
    test, an assertion failure with captured output, an uncaught exception in an
    imported module, `sys.exit(0)`, a test that prints and returns (passes and
    shows no output), and a test that reads `input()` (gets `None`) and checks
    `sys.args()` is empty.
  - An explicit file path runs only that file; `--check` on both directories
    exits 0 with no output; a type error in one test file prevents every test
    from running; a directory with no tests and a `test_*` function with a
    parameter are errors; unknown options and extra paths are usage errors.

## Implementation plan

1. `compiler/parser.lua`, `compiler/bind.lua`, `compiler/check.lua`,
   `compiler/lower.lua`, `runtime/core.lua`: `Assert` and `AssertionError`.
2. `compiler/bind.lua` test mode and `entry.tests`; `compiler/emit.lua` test
   chunks.
3. `compiler/runner.lua` and the `test` command in `compiler/cli.lua`, including
   `USAGE`.
4. `willow`: export `WILLOW`.
5. `examples/cart/`: `cart.wlo` (a `Cart` record with `add`, `total`, and
   `apply_discount`, which raises `ValueError` for a percentage outside
   0–100), `main.wlo` printing a receipt, and `test_cart.wlo` with passing tests
   that use `assert` and catch the `ValueError`.
6. `tests/suites/failing/`: `shop.wlo` and `test_shop.wlo` with the cases above.
7. `editors/vscode/` files.
8. Tests above.
9. Fold §17 into `docs/spec.md`, add `willow test` and editor setup to
   `README.md`, and check off the milestone in `agents/todo.md`.

## Documentation updates

- `docs/spec.md`: §8 lists `assert` and states its rules; §9 narrowing and
  control transfer mention it; §10 lists `AssertionError`; a §1
  paragraph points to the test command, described with the `WILLOW` variable in
  a new `### Tests` subsection of §12 (Modules). The §17 heading stays
  with one sentence saying where its rules live; the top pointer and the
  milestones introduction say sections 18–24 are unimplemented.
- `README.md`: `willow test` usage lines and an "Editor support" section.
- `agents/todo.md`: check off "Application tests and editor basics (spec §17)".
