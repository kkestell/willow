# Review: input and output

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-15-009-input-and-output.md` against §20 of `willow.md`: `compiler/bind.lua`, `compiler/check.lua`, `compiler/lower.lua`, `compiler/emit.lua`, `compiler/cli.lua`, `runtime/core.lua`, `runtime/stub.c`, `tests/run.lua`, the new program tests, the unit and CLI tests, `examples/number.wlo`, `README.md`, and `agents/todo.md`. Also read the surrounding runtime error paths (`__wlo_fail`, `__wlo_host_fail`, `__wlo_try`, `__wlo_run`), the emitter's chunk layout, and the lexer's UTF-8 patterns. Executables were exercised on macOS only; Linux was not run.

## Fixed

None.

## Findings

No open findings.

## Checks run

- `make test`: 183 passed, 0 failed.
- `read_file` and `write_file` on a directory: each raised a catchable `OSError` with `cannot read sub: Is a directory` and `cannot write sub: Is a directory`.
- `input()` with stdin redirected from a directory and with stdin closed: each terminated with status 1 and `cannot read input: <reason>` at the call site.
- `eprint` of a float, and `exit(4)` reached through `willow run` with an argument: printed `1.5` to stderr and exited with status 4.
- `input(1)`, `print()`, and a user function named `exit`: each reported a diagnostic rather than crashing the checker.
- `main(xs: list[ str ])` with spaced type syntax: accepted and received its arguments.

## Verdict

The change implements §20 and the plan as written. Arguments reach `main` the same way through `run`, compiled Lua, and built executables; `input`, `eprint`, the file built-ins, `exit`, and `OSError` behave as specified. No findings; ready to commit.
