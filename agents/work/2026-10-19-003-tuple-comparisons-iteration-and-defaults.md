# Tuple comparisons, iteration, and defaults

## Plan

`agents/plans/2026-10-19-003-tuple-comparisons-iteration-and-defaults.md`

## Summary

Tuple equality, ordering, iteration, and tuple defaults work as planned, and
`list_contains_converted` replaces `list_contains_boxed`. The plan's goal is met.

## Decisions

- `types.items` puts a member that subsumes earlier ones after the members it
  keeps, so `tuple[ValueError, int, Exception]` iterates as `int | Exception`.
- `tests/unit/lower_test.lua` shows a conversion-step literal by its `float`
  entry, as `{box}`.

## Checks run

- `make test` — 281 passed, 0 failed.

## Manual verification

1. `tests/programs/tuples.out` was read line by line against the cases in
   `comparisons`, `iteration`, and `defaults`: `tuple[int | float]` holding `1`
   is unequal to `tuple[float]` holding `1.0`, and holding `1.0` is equal; a NaN
   in the first position makes both `<` and `>` false; iterating
   `(1, 2.5, None)` gives `2.5` as a float.

   ```sh
   ./willow run tests/programs/tuples.wlo | diff - tests/programs/tuples.out
   ```

   No diff.
