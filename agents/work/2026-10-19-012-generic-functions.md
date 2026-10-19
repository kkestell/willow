# Generic functions with explicit specialization

## Plan

`agents/plans/2026-10-19-012-generic-functions.md`

## Summary

File-level and nested functions take type parameters, bodies are checked once
with opaque type variables, unions allow a type parameter only with `None`,
and `f[int](...)` specializes calls with substituted parameter and return
types. The plan's goal is met.

## Departures from the plan

- `types.substitute` returns a type unchanged unless it mentions a type
  parameter; otherwise recursive aliases such as `json.Json` would recurse
  forever.
- A specialized call is allowed as a statement.
- `ok[int](1)` on a non-generic declared function reports "'ok' is not
  generic" rather than becoming an index call.
- Methods with type parameters report "generic methods are not supported";
  generic methods are a later task.

## Checks run

- `make test` — 307 passed, 0 failed.

## Manual verification

1. `tests/programs/generics.out` was read against the program, including
   `first[int | float]` returning a boxed `2.5` that still tests as a float.

   ```sh
   ./willow run tests/programs/generics.wlo
   ```
