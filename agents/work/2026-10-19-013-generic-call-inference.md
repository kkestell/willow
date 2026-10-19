# Generic call inference

## Plan

`agents/plans/2026-10-19-013-generic-call-inference.md`

## Summary

Generic calls without type arguments infer them from argument types and,
for parameters the arguments leave open, from the expected result. Each type
parameter takes the one candidate that the others are assignable to, and
conflicting or missing candidates are reported. Lambda arguments wait for the
other arguments, then infer their result. The plan's goal is met.

## Checks run

- `make test` — 307 passed, 0 failed.

## Manual verification

1. The new `inferred` cases in `tests/programs/generics.wlo` print the expected
   values, including `map_list(lambda x: str(x) + "!", [7])` inferring
   `U = str`.

   ```sh
   ./willow run tests/programs/generics.wlo | tail -9
   ```

   `3 a 2 5 0 1 4 7! 1`.
