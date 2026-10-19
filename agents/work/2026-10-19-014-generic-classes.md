# Generic classes and methods

## Plan

`agents/plans/2026-10-19-014-generic-classes.md`

## Summary

Classes and methods take type parameters. Annotations require full type
arguments, constructors infer them or take them explicitly, and field and
method types are substituted per specialization. Specializations are
invariant with one per union, `isinstance` matches by class name, exception
classes cannot be generic, and all of it works across modules. The plan's goal
is met.

## Departures from the plan

- `collect` in `compiler/check.lua` also matches a specialization parameter
  against a specialization argument of the same class, so
  `length(node: Node[T] | None)` infers `T` from a `Node[int]`.
- A `MethodCall` with method type parameters skips re-checking arguments that
  inference already checked, as generic function calls do.

## Checks run

- `make test` — 311 passed, 0 failed.

## Manual verification

1. `tests/programs/generic_classes.out` was read against the program, including
   `s.map(lambda x: len(x) + 10)` inferring `U = int` and a `Box[int | float]`
   keeping `2.5` as a float.

   ```sh
   ./willow run tests/programs/generic_classes.wlo
   ```
