# Keyword-only parameters

## Plan

`agents/plans/2026-10-19-005-keyword-only-parameters.md`

## Summary

A bare `*` makes the parameters after it keyword-only in functions and
methods, keyword-only defaults may come in any order, and positional arguments
for them are rejected. The plan's goal is met.

## Decisions

- The "'*' must be followed by a keyword-only parameter" check runs after the
  parameter list, so `def f(*, *, a: int)` reports the second `*` instead.

## Checks run

- `make test` — 286 passed, 0 failed.

## Manual verification

1. The new calls in `tests/programs/named_arguments.wlo` print the expected
   values, including keywords given out of declaration order and omitted
   defaults.

   ```sh
   ./willow run tests/programs/named_arguments.wlo | tail -3
   ```

   `a 100 True x`, `b 5 False t`, `6 12`.
