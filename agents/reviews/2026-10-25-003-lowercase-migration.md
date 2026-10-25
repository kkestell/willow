# Lowercase migration review

## Scope and coverage

Reviewed the staged lowercase-literal migration: library sources, examples,
tests, benchmarks, documentation (`bootstrap/core/API.md`, `compiler/init.wlo`
help text), and VSCode editor support moved to `true`/`false`/`none`.
Traced the bootstrap transition: `bootstrap/legacy_literals.awk`,
`bootstrap/prepare.sh` legacy/current modes, `bootstrap/stage0`
lexer/parser/check/main, `Makefile` stage1/stage2/current wiring, and
`bootstrap/tests/stage1.sh`/`stage2.sh`. Confirmed the frozen stage 1
compiler is preserved (no `bootstrap/stage1/*.wlo` staged). Inspected the
regression coverage (`capitalized_literals_are_names`, `lexer_test`
capitalized-as-names case) and the completed todo item.

Coverage limits:

- Ran the full `make bootstrap-test` on macOS arm64 during this review.
- Linux was not exercised; the requested Linux validation remains with the user.

## Summary

No findings.

## Checks run

- Inspected the full staged diff. Compiler, core, library, example,
  benchmark, and test changes are mechanical literal and comment updates;
  remaining capitalized spellings are intentional (`True`/`False`/`None` as
  names in the new regression test and `lexer_test`, `"None"` helper strings
  in subprocess/process tests).
- Verified `bootstrap/stage0` accepts both spellings normally and lexes
  lowercase literals as names under `--legacy`, matching the frozen stage 1
  behavior; `check.c`/`parser.c` diagnostics use the lowercase spelling.
- Verified `prepare.sh` modes: stage 1 embeds legacy core/library text,
  stage 2 legacy sources go to the frozen compiler, and stage 2 current
  sources plus lowercase embeds go to the self-build. `stage1.sh`/`stage2.sh`
  use the matching flags and directories, including the coroutine fixture path.
- Audited `legacy_literals.awk` string/comment handling with a focused
  conversion check; no rewritten source (compiler, core, lib) interpolates a
  literal inside an f-string, and internal `"true"`/`"false"`/`"none"` markers
  and type-name strings stay consistent within each build.
- Ran focused checks with the existing build: lowercase optional program and
  capitalized-as-names program behaved as expected; `lexer_test`,
  `parser_test`, and `types_test` binaries passed.
- `git diff --cached --check` is clean.
- Ran `make bootstrap-test` on macOS: exit 0. Bootstrap SSA fixpoint matched;
  stage 0 L0 programs 107 passed; stage 1 unit tests passed; stage 2 unit,
  driver, HTTP, and willow2 suites passed (294 passed); `make test` passed
  (142 passed, including both literal conformance programs).

## Verdict

No confirmed defects within the requested scope. No implementation changes
were needed.
