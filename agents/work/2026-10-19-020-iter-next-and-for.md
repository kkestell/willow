# `iter`, `next`, `StopIteration`, and `for` over iterables

## Plan

`agents/plans/2026-10-19-020-iter-next-and-for.md`

## Summary

`StopIteration` is a built-in exception, `iter` and `next` call the `iter` and
`next` methods of values satisfying `Iterable[T]` and `Iterator[T]`, and `for`
loops over classes, protocol values, and bounded type parameters that satisfy
`Iterable[T]`. Only `StopIteration` from advancement ends such a loop, and an
iterator left early resumes where it stopped. The plan's goal is met.

## Decisions

- Added `tests/programs/iteration_traceback.wlo`, because advancement runs
  under `pcall`. An uncaught exception raised by `next` still reports the
  method and the loop's line in its traceback.

## Checks run

- `make test`: 323 passed, 0 failed.

## Manual verification

1. `iter` and `next` work as function values when an expected callable type
   fixes their argument.

   ```sh
   # advance: (Countdown) -> int = next; start: (Countdown) -> Countdown = iter
   ./willow run val.wlo
   ```

   Printed `2` for `advance(start(Countdown(3)))`.
