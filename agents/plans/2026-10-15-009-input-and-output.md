# Input and output

## Goal

Implement §20: `main` may take `args: list[str]`; `input`, `eprint`,
`read_file`, `write_file`, and `exit` become built-in functions and `OSError` a
built-in exception class. `willow run` passes everything after the source path
to the program, and compiled Lua and built executables receive their own
command-line arguments.

## Related code

- `compiler/bind.lua` — `builtins` and `exceptions` tables; the `main`
  signature check in `M.bind`.
- `compiler/check.lua` — `builtins` signatures (each assumed to take one
  argument), the `Call` case of `check_expression`, and `check_statement`, where
  `Raise` returns true to transfer control.
- `compiler/lower.lua` — the `Builtin` branch of the `Call` case, which picks
  `print` or `print_float`.
- `compiler/emit.lua:379` — the entry invocation `__wlo_run(main)`.
- `runtime/core.lua` — `__wlo_write`, `__wlo_print`, `__wlo_fail`,
  `__wlo_host_fail`, and `__wlo_run`.
- `compiler/lexer.lua:31` — the UTF-8 sequence patterns the runtime check
  copies.
- `compiler/cli.lua` — `parse_args`, `USAGE`, and the `run` branch that calls
  the loaded chunk.
- `runtime/stub.c` — `main(void)` loads the payload and calls it with no
  arguments.
- `tests/run.lua` — program tests; stdin is currently inherited.
- `tests/unit/cli_test.lua` — end-to-end tests through `run`, `compile`, and
  `build` in a temporary directory.

## Decisions

- **Passing arguments.** Every route passes the program arguments as the
  generated chunk's varargs: `luajit prog.lua a b` already does; the stub calls
  the chunk with `argv[1..]` pushed as strings; `run` calls
  `chunk(unpack(program_args))`. When `main` takes a parameter the emitter ends
  with `__wlo_run(main, __wlo_args(...))`, otherwise `__wlo_run(main)` as today.
  `__wlo_run(main, ...)` passes its extra arguments through `xpcall`.
- **Invalid UTF-8 arguments.** `__wlo_args(...)` builds the list and, for the
  first argument that is not valid UTF-8, writes
  `error: argument <n> is not valid UTF-8` to stderr and exits 1, where `<n>`
  counts from 1. Arguments are only checked when `main` takes them.
- **Entry signature.** `main` may have no parameters or one parameter of type
  `list[str]`, under any name, and must return `None`. The error becomes
  `main must take no parameters or one list[str] parameter and return None`.
- **`run` arguments.** In `parse_args`, once `run` has its input path, every
  later argument is a program argument, including `-o` and other `-` options.
  Options before the path are still rejected. `parse_args` returns the program
  arguments as a fourth value. Usage line: `willow run <file> [args...]`.
- **Built-in signatures.** `check.lua`'s `builtins` entries get a `params` list
  instead of `param`; `"any"` marks an argument that `print`, `eprint`, `str`,
  and `len` check by name as today. `input` takes none and returns
  `str | None`; `read_file(str) -> str`; `write_file(str, str) -> None`;
  `exit(int) -> None`; `eprint` checks its argument like `print`.
- **`exit` as a transfer.** `check_statement` returns true for a `CallStmt`
  whose call targets the built-in `exit`. Lowering and emitting need nothing
  more: the runtime never returns from `__wlo_exit`.
- **Runtime helpers** in `runtime/core.lua`:
  - `__wlo_valid_utf8(text)` skips ASCII runs with `find("[\128-\255]")` and
    matches each multibyte sequence against the lexer's patterns.
  - `__wlo_write(file, text, site)` takes the stream; `__wlo_eprint` and
    `__wlo_eprint_float` mirror the print helpers on `io.stderr`. Both streams
    keep the message `cannot write output`.
  - `__wlo_input(site)` reads with `io.stdin:read("*L")` so a final line
    without `\n` keeps a trailing `\r`; it removes `\n` and then a `\r` before
    it. A read error is a host failure `cannot read input: <reason>`. Invalid
    UTF-8 raises `ValueError` `invalid UTF-8`.
  - `__wlo_read_file(path, site)` and `__wlo_write_file(path, text, site)` use
    `io.open` in binary mode. `io.open` reports `<path>: <reason>`, so its
    `#path + 3` prefix is dropped; `read`, `write`, `flush`, and `close` report
    the reason alone. Failures raise `OSError` with
    `cannot read <path>: <reason>` or `cannot write <path>: <reason>`.
    `read_file` checks UTF-8 after reading.
  - `__wlo_exit(status, site)` raises `ValueError` `exit status out of range`
    outside 0..255, then calls `os.exit(status)`, which skips every pending
    `finally` and the `xpcall` in `__wlo_run`.
- **Lowering.** Built-ins lower to helpers of the same name, as `print` does.
  `print` and `eprint` both pick their `_float` helper for float arguments.
- **Program test stdin.** `tests/run.lua` feeds `NAME.in` to stdin when it
  exists and `/dev/null` otherwise, so input tests are program tests and no
  test reads the terminal.

## Test plan

Program tests in `tests/programs/`:

- `input_lines.wlo` with `input_lines.in` holding `a\nb\r\n\r\nlast\r` with no
  final newline: prints `len(line)` for each line until `None` (1, 1, 0, 5),
  showing that `\n` and `\r\n` are removed and the final line keeps its `\r`.
- `input_empty.wlo` with no `.in`: `input()` is `None` at once.
- `invalid_utf8.wlo` with `invalid_utf8.in` holding `ok\n\xff\n`: the first
  `input()` succeeds, the second raises `ValueError: invalid UTF-8`, caught and
  printed; `read_file("invalid_utf8.in")` raises the same, caught; a
  `read_file("missing.txt")` `OSError` is caught and prints
  `cannot read missing.txt: No such file or directory`; a final uncaught
  `read_file("missing.txt")` reports `OSError` with status 1.
- `eprint_values.wlo`: `eprint` of an int, a float, a string, and `None` lands
  in `.err`; the program then raises so the expected status is 1.

Unit tests:

- `bind_test.lua` `main_required`: `def main(args: list[str]) -> None` binds;
  `main(x: int)`, `main(a: list[str], b: int)`, and `main() -> int` report the new
  message.
- `check_test.lua`: a statement after `exit(0)` is unreachable;
  `def f() -> int:` ending in `exit(1)` needs no return; `input()` is
  `str | None` and must be narrowed; `exit("x")`, `write_file("a")`, and
  `eprint([1])` are rejected; `OSError` is catchable by name.

CLI tests in `cli_test.lua`:

- `arguments_reach_main`: a program printing each argument and `len(args)`
  gives the same output for `run prog.wlo a '-o' '--x' 'b c'`, `luajit` on the
  compiled file, and the built executable, each with the same arguments.
- `check`, `compile`, and `build` with an extra argument still fail with
  `unexpected argument`; replace the `run a.wlo b.wlo` and `run a.wlo -o out.lua`
  usage cases with `check a.wlo b.wlo` and `check a.wlo -o out.lua`; update
  `USAGE`.
- `invalid_utf8_argument`: `run` with `$'\xff'` exits 1 with
  `error: argument 1 is not valid UTF-8` and runs nothing.
- `exit_status`: `exit(3)` after a `print` gives status 3 and the output;
  `exit(0)` inside `try` with a `finally` that prints shows the `finally` does
  not run; `exit(256)` and `exit(-1)` report
  `ValueError: exit status out of range` with status 1. Run the `exit(3)`
  program through the built executable too.
- `file_round_trip`: write text with `\r\n` and non-ASCII through `write_file`,
  read it back with `read_file`, and compare; the file on disk matches
  byte for byte; writing into a missing directory raises a caught `OSError`
  beginning `cannot write missing/out.txt: `.
- `number_example`: run `examples/number.wlo` from a temporary directory with
  `printf 'apple\nbanana\n'` on stdin and argument `out.txt`; stdout is
  `wrote 2 lines` and `out.txt` holds the two numbered lines; with no argument it
  prints the usage line to stderr and exits 2.

## Implementation plan

1. `runtime/core.lua`: `__wlo_valid_utf8`, the stream argument to
   `__wlo_write`, `__wlo_eprint`, `__wlo_eprint_float`, `__wlo_input`,
   `__wlo_read_file`, `__wlo_write_file`, `__wlo_exit`, `__wlo_args`, and extra
   arguments through `__wlo_run`.
2. `compiler/bind.lua`: add `input`, `eprint`, `read_file`, `write_file`, and
   `exit` to `builtins` and `OSError` to `exceptions`; accept the `main(args)`
   signature.
3. `compiler/check.lua`: `params` lists for built-ins, the new signatures,
   `eprint`'s printable check, and `exit` as a transfer.
4. `compiler/lower.lua`: `eprint_float` beside `print_float`.
5. `compiler/emit.lua`: `__wlo_run(main, __wlo_args(...))` when the entry
   `main` has a parameter.
6. `compiler/cli.lua`: program arguments for `run`, the usage line, and
   `chunk(unpack(program_args))`.
7. `runtime/stub.c`: `main(int argc, char **argv)`; `luaL_checkstack` and push
   `argv[1..]` before `lua_pcall(L, argc - 1, 0, 0)`.
8. `tests/run.lua`: stdin from `NAME.in` or `/dev/null`.
9. `examples/number.wlo`: the §20 example.
10. The tests above.
11. `agents/todo.md`: check off the fourth slice.

## Documentation updates

- `README.md` usage: show `willow run number.wlo out.txt` passing arguments and
  that compiled and built programs take their own; the exit status sentence
  notes that a program can choose its status with `exit`.
