# Review: compile and build executables

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-15-008-compile-and-build-executables.md`: `compiler/cli.lua`, `runtime/stub.c`, `Makefile`, `.gitignore`, `tests/unit/cli_test.lua`, `README.md`, and `willow.md`. Also read the related runtime code in `runtime/core.lua` (frame matching by chunk source, `__wlo_run`) and the `willow` launcher. Executables were exercised on macOS arm64 only; Linux coverage comes from the caller's Debian bookworm `make test` run and a Linux syntax check of the stub.

## Fixed

- **Dead buffer-size check in the Linux stub path** (`runtime/stub.c:30`): The Linux branch of `executable_path` checked for a buffer smaller than 16 bytes, but its only caller passes a 4096-byte buffer, so the branch could never run. Removed the check.

## Findings

No open findings.

## Checks run

- `make test`: 173 passed, 0 failed (macOS arm64, stub rebuilt).
- Built and ran an executable through a `PATH` symlink and from another working directory; it printed the expected output with exit status 0. The file mode was `0755`.
- Built a program that raises an uncaught `ValueError`; the executable's stderr and exit status 1 matched `willow run`.
- `otool -L runtime/stub`: links only `libSystem`.
- `gcc -fsyntax-only -Wall` on `runtime/stub.c` in a `gcc:12` Linux container: clean.

## Verdict

The change implements the plan as written. `compile` keeps the previous standalone Lua output, and `build` produces working self-contained executables that match `run`. One minor simplification was fixed, and the work is ready to commit.
