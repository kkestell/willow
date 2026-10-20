# `iter`, `next`, `StopIteration`, and `for` over iterables review

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-19-020-iter-next-and-for.md`: `StopIteration` and the
`iter`/`next` built-ins in `compiler/stdlib.lua`; `check_method`, `iteration`,
`advancement`, the built-in call rewrite, and the `For` statement in
`compiler/check.lua`; the `For` iterable lowering and shared `dispatch` in
`compiler/lower.lua`; `__wlo_iterate` in `runtime/core.lua`; and the new tests.
Traced the rewritten `MethodCall` nodes through lowering, the `iter`/`next`
function-value path, captured-variable narrowing around `try`, and how
advancement errors reach the traceback, and compared the behavior with spec
§3, §8, and §11.

Gaps:

- Built-in values with `iter` methods are the next task. The native-helper
  branch of the `for` lowering has no native type with `next` to reach it yet,
  so it was read but not exercised.

## Summary

| ID | Severity | Category       | Fix   | Title                                                             |
| -- | -------- | -------------- | ----- | ----------------------------------------------------------------- |
| F1 | Medium   | Correctness    | Fixed | A `for` loop's implicit calls keep captured narrowing in `except` |
| F2 | Low      | Error handling | Fixed | VM errors during advancement lose their location                  |
| F3 | Low      | Comments       | Fixed | `check_expression` comment sits above `check_method`              |

## F1. A `for` loop's implicit calls keep captured narrowing in `except`

Medium · Correctness · Fixed · `compiler/check.lua:1389`

The `for` statement checks its implicit `iter` and `next` calls through
`check_method` directly, so the `calls` counter does not change. `check_try`
uses that counter to decide whether an `except` or `finally` clause can start
after a call. A `try` body whose only calls are a loop's `iter` and `next` keeps
the narrowing of captured variables in its handlers. A `next` method that
rebinds a captured variable through a stored closure then makes a narrowed
`int` hold `None`.

### Evidence

With `x: int | None` narrowed by `if x is not None`, a `for` over an iterator
whose `next` calls a closure setting `x = None` and then raises `ValueError`,
and `print(x + 1)` in the `except ValueError` handler, the program compiled and
failed at run time with `attempt to perform arithmetic on local 'a' (a nil
value)`.

### Fix

The `For` statement counts its implicit calls by incrementing `calls` when it
records `iter_call` and `next_call`. The program above now reports
`operator '+' cannot be applied to int | None and int`. Added a regression
test to the `closures` case in `tests/unit/check_test.lua`; it fails without
the fix.

## F2. VM errors during advancement lose their location

Low · Error handling · Fixed · `runtime/core.lua:443`

`__wlo_iterate` called `next` under `pcall`. A raw VM error such as stack
overflow inside `next` was caught as a string and raised again from the loop,
where the top-level handler recorded the frames. The report pointed at the
`for` line in `main` and dropped every frame inside `next`.

### Evidence

A `next` that recursed without bound reported `error: stack overflow` at the
`for` line with only `in main`; the same call made directly reported the
recursive function and its frames.

### Fix

`__wlo_iterate` calls `next` through `xpcall` with `__wlo_catch`, the handler
`__wlo_try` uses, so a VM error records its frames where it happens. Every
error is then a table, so the `StopIteration` test drops its `type` check. The
stack overflow now reports `in deep` and its callers.

## F3. `check_expression` comment sits above `check_method`

Low · Comments · Fixed · `compiler/check.lua:709`

Extracting `check_method` placed it between `check_expression`'s comment and
its definition, so the comment described the wrong function.

### Fix

Moved the comment back above `check_expression`.

## Checks run

- Reproduced F1 and F2 with small programs under `./willow run`; both behave
  correctly after the fixes.
- Ran `tests/unit/check_test.lua` with and without the F1 fix: the new test
  fails without it and passes with it.
- `make test`: 323 passed, 0 failed.

## Verdict

The change implements `iter`, `next`, `StopIteration`, and `for` over iterables
as the plan and spec describe. F1 was a soundness gap in captured narrowing;
F2 and F3 were minor. All three are fixed.
