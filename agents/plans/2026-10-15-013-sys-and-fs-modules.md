# `sys` and `fs` modules

## Goal

Implement the eighth slice in `docs/spec.md` §1, §11, and §14. `eprint`,
`read_file`, `write_file`, and `exit` stop being built-in names and become
members of the compiler-provided modules `sys` and `fs`, `sys.args()` replaces
the `main(args: list[str])` entry signature, and a program's own `sys.wlo` or
`fs.wlo` shadows the compiler-provided module.

## Related code

- `compiler/loader.lua` — `M.load(path, source, library)` opens
  `directory .. name .. ".wlo"` and falls back to `library` on `ENOENT`.
- `compiler/bind.lua` — `builtins` maps built-in names to
  `{ kind = "Builtin", name }` targets; `declare` fills `module.imported[name]`
  from `modules_by_name`; `lookup(from, module, name, span)` reads
  `module.declarations[name]` and `module.name`; the `MethodCall` branch of
  `resolve_expression` turns `module.name(...)` into a `Call` whose `name` is
  `module.name`; `M.bind` checks the `main` signature.
- `compiler/check.lua` — `builtins` holds built-in signatures keyed by target
  name; the `Call` branch compares `node.name` for `print`, `eprint`, `str`,
  conversions, and `len`; the `CallStmt` branch treats a `Builtin` target named
  `exit` as a transfer.
- `compiler/lower.lua` — the `Builtin` branch of the `Call` case picks the helper
  from `node.name`; `helper(name, args, span)` records a site.
- `compiler/emit.lua` — the last line emits
  `__wlo_run(main, __wlo_args(...))` when `main` has a parameter.
- `runtime/core.lua` — `__wlo_args(...)` validates every argument before `main`
  runs and exits with `error: argument N is not valid UTF-8`; `__wlo_run(main,
  ...)` passes the list to `main`; `__wlo_eprint`, `__wlo_eprint_float`,
  `__wlo_read_file`, `__wlo_write_file`, and `__wlo_exit` already implement the
  moved functions.
- `examples/number.wlo`, `tests/programs/eprint_values.wlo`,
  `tests/programs/invalid_utf8.wlo`, `tests/unit/bind_test.lua`
  (`main_required`), `tests/unit/check_test.lua` (`io_builtins`),
  `tests/unit/cli_test.lua` (`arguments_reach_main`, `invalid_utf8_argument`,
  `exit_status`, `file_round_trip`) — use the old names and signature.

## Decisions

- **Where the modules are declared.** `bind.lua` exports `M.modules`, a table
  of the compiler-provided modules keyed by name. Each is
  `{ name = "sys", declarations = { args = Builtin, eprint = Builtin,
  exit = Builtin } }` and `{ name = "fs", declarations = { read_file = Builtin,
  write_file = Builtin } }`, where each `Builtin` is a
  `{ kind = "Builtin", name }` target like the entries of `builtins`. `lookup`
  and the `MethodCall` branch work on these tables unchanged, so `sys.exit(1)`
  binds to the same target shape as a built-in call. The modules are not added
  to the module list: they have no source, path, or functions to check, lower,
  emit, or compare against `-o`.
- **How the loader skips them.** `loader.lua` requires `compiler.bind` and
  checks `bind.modules[import.name]` after the local open fails with `ENOENT`,
  before trying `library`. A compiler-provided name is then neither opened nor
  visited. `declare` sets
  `module.imported[name] = modules_by_name[name] or M.modules[name]`, so a
  loaded `sys.wlo` wins and the compiler-provided module fills in otherwise.
  Unit tests that call `bind.bind` directly get the same fallback without the
  loader.
- **Keying built-in behavior on the target.** `check.lua` and `lower.lua` use
  `target.name` instead of `node.name` wherever they select built-in behavior,
  because a module call's `node.name` is `sys.eprint`. Arity errors keep
  `node.name` so they read `'sys.exit' expects 1 argument`. The `CallStmt`
  transfer test already keys on the target, so a shadowing module's `exit`,
  a `Function` target, does not transfer.
- **Signatures.** `check.lua` keeps the `eprint`, `read_file`, `write_file`, and
  `exit` entries of `builtins` and adds
  `args = { params = {}, result = types.list(types.str) }`. `bind.lua` removes
  the four names from `builtins`, so programs may declare them.
- **Entry signature.** `M.bind` requires `#main.params == 0` and a `None`
  return, with the message `main must take no parameters and return None`.
- **Arguments at runtime.** `emit.lua` always emits
  `__wlo_run(main, ...)`. In `core.lua`, `__wlo_run(main, ...)` stores the
  varargs in a file-level `local __wlo_argv` as `{ n = select("#", ...), ... }`
  and calls `xpcall(main, __wlo_catch)`. `__wlo_args(site)` replaces the old
  `__wlo_args(...)`: it validates each argument with `__wlo_valid_utf8`,
  raising `ValueError` `invalid UTF-8` through `__wlo_fail` at `site`, and
  returns a new `__wlo_list` copy on every call. Nothing runs before `main`.
- **The §14 example.** It needs arguments and a file, which program tests do
  not supply, so it becomes `examples/chars.wlo` with a `chars_example` test in
  `cli_test.lua` next to `number_example`.

## Test plan

- `tests/unit/bind_test.lua`: `main_required` rejects `main(args: list[str])`
  with the new message; a new `standard_modules` test binds
  `import sys\nimport fs` and checks that `sys.args()`, `sys.exit(0)`, and
  `fs.read_file('a')` resolve to `Builtin` targets named `args`, `exit`, and
  `read_file`; `sys.missing()` reports
  `module 'sys' has no function, record, or alias 'missing'`; `sys` as a
  value reports `module 'sys' cannot be used as a value`; declaring
  `def exit(status: int) -> None` and `def eprint(x: int) -> None` is accepted.
- `tests/unit/check_test.lua`: `io_builtins` uses `sys.exit`, `sys.eprint`,
  `fs.read_file`, and `fs.write_file`; `sys.exit(0)` followed by a statement is
  unreachable; `def f() -> int:` ending in `sys.exit(1)` checks; a program's own
  `def exit(status: int) -> None` called before `print(1)` checks because it is
  not a transfer; `sys.args()` has type `list[str]`; `sys.exit('x')`,
  `fs.write_file('a')`, and `sys.eprint([1])` report the existing messages with
  the qualified name.
- `tests/programs/eprint_values.wlo` and `tests/programs/invalid_utf8.wlo`
  import `sys` and `fs` and use the qualified names; expected output is
  unchanged.
- `tests/modules/shadow_sys/`: `sys.wlo` declares `def exit(status: int) ->
  None` that prints `exit <status>` and `def args() -> str` returning
  `local sys`; `main.wlo` calls `sys.exit(3)`, prints `sys.args()`, and prints
  `after`; `main.out` shows all three lines, proving the local module shadows
  the compiler-provided one and its `exit` does not transfer.
- `tests/unit/cli_test.lua`:
  - `arguments_reach_main` becomes `arguments_reach_sys_args`: the program
    imports `sys`, calls `sys.args()` twice, and prints the length and each
    argument from the second call, through `run`, compiled, and built output,
    with the same arguments as today.
  - `invalid_utf8_argument`: `main` prints `1`, then calls `sys.args()` inside
    `try` and prints the caught `ValueError` message, then calls `sys.args()`
    again uncaught; stdout is `1\ninvalid UTF-8\n`, stderr is the uncaught
    report at the second call's line and column, status 1.
  - `exit_status` and `file_round_trip` use `sys.exit`, `fs.write_file`, and
    `fs.read_file`; the `exit status out of range` report keeps its location.
  - `chars_example`: `examples/chars.wlo` with no arguments exits 2 with
    `usage: chars <file>` on stderr; with a missing file exits 1 with
    `cannot read missing.txt: No such file or directory`; with a file holding
    `héllo\n` prints `6`.
  - `number_example` keeps passing with the rewritten example.

## Implementation plan

1. `compiler/bind.lua`: remove `eprint`, `read_file`, `write_file`, and `exit`
   from `builtins`; add `M.modules` with `sys` and `fs`; fall back to
   `M.modules[name]` in `declare`; require `main` to take no parameters with
   the new message.
2. `compiler/loader.lua`: require `compiler.bind` and skip opening `library`
   for names in `bind.modules`.
3. `compiler/check.lua`: add the `args` signature; select built-in behavior by
   `target.name`.
4. `compiler/lower.lua`: select the helper by `node.target.name`.
5. `compiler/emit.lua`: emit `__wlo_run(main, ...)` unconditionally.
6. `runtime/core.lua`: add `__wlo_argv`, store the varargs in `__wlo_run`, and
   rewrite `__wlo_args(site)` as described.
7. `examples/number.wlo`: import `sys` and `fs`, take no parameters, and read
   `sys.args()`. Add `examples/chars.wlo` from §14.
8. Update and add the tests above.
9. `agents/todo.md`: check off the eighth slice.
