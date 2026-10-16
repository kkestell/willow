# Runtime helper locals and compiler fixes review

## Scope and coverage

Reviewed the staged changes implementing
`agents/plans/2026-10-16-010-runtime-helper-locals.md` (F1) and the trivial
fixes F2–F8 from `agents/reviews/2026-10-16-011-compiler.md`. This covered
`compiler/runtime.lua`, `emit.lua`, `lower.lua`, `check.lua`, and
`manifest.lua`, their callers in the lexer, manifest reader, CLI, and test
runner, the optional runtime files they assemble, and the added and modified
tests. Each fix was traced against the plan, the earlier review's proposed fix,
and `docs/spec.md`.

Gaps:

- Execution checks ran on macOS only; Linux was not exercised.

## Summary

No findings.

## Checks run

- `make test`: 259 passed, 0 failed.
- Confirmed no optional runtime file references another optional library's
  helpers, and core references none, so moving helper locals into their blocks
  breaks no lexical reference. Helper names emitted literally by the compiler
  and loaded by the lexer are all core helpers.
- Re-ran the F1 reproduction from the earlier review: it loads and runs, and an
  error raised inside an optional helper still reports the Willow source
  location. Running its compiled Lua with global writes trapped showed no
  runtime global assignments.
- Confirmed integer `-0` defaults still print `0` after the F3 change, and that
  membership with bytes in dictionaries and `list[bytes | None]` gives correct
  results after F4.
- Confirmed `assert` is reserved, so the test footer's remaining global cannot
  be shadowed after F5.

## Verdict

The staged changes fix F1–F8 as planned and add focused regression tests. No
findings; commit the staged work.
