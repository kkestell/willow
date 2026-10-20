# Generator functions review

## Scope and coverage

Reviewed the staged generator-functions change against
`agents/plans/2026-10-20-002-generator-functions.md` and spec §8 Generators:
`yield` parsing, `fn.generator` binding and call counting, the checker's
annotation, return, `finally`, and narrowing rules, lowering and emission of
generator bodies and `Yield`, the `cancel` departure in `__wlo_try` and `Try`
emission, the generator runtime in `runtime/core.lua`, the `<generator>`
dispatch entry in `compiler/stdlib.lua`, and the new tests. Focused programs
exercised aliases to `Iterator[T]`, boxed and union yield values, generic class
methods, tuple yields, nested `finally` cleanup on close, `break` in `finally`,
`return` inside `try`/`finally`, protocol conversions to `Iterable[T]` and
`Iterator[T]`, `enter` and `exit`, and deep generator nesting.

Gaps:

- Close's full behavior (cleanup errors, inner-to-outer order with `with`) is
  the next todo task and was reviewed only as far as the plan requires.
- Nesting tens of thousands of generators exhausts the C stack through nested
  `coroutine.resume` and ends the process without a diagnostic, which spec
  §10 "Failures that are not exceptions" permits.

## Summary

| ID | Severity | Category   | Fix   | Title                                         |
| -- | -------- | ---------- | ----- | --------------------------------------------- |
| F1 | Low      | Simplicity | Fixed | `__wlo_generator_close` sets its state twice |

## F1. `__wlo_generator_close` sets its state twice

Low · Simplicity · Fixed · `runtime/core.lua:1222`

For a suspended generator, `close` set `state` to `"done"`, then immediately to
`"running"`, then to `"done"` again, carrying a `suspended` flag to bridge the
first assignment. The first assignment had no effect on that path.

### Fix

`close` now returns early, marking the generator `"done"`, when it is not
suspended; the suspended path sets `"running"`, resumes with the cancel value,
and sets `"done"`.

## Checks run

- Focused `./willow run` programs for the cases listed in scope: all printed
  the expected output; `break` in `finally` was rejected; the generator
  annotation error reported for `main`.
- `make test`: 329 passed, 0 failed.

## Verdict

The change implements the plan and the specified generator behavior. The one
finding, F1, was a small simplification in `close`, now fixed.
