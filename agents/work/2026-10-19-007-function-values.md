# Declared functions as values

## Plan

`agents/plans/2026-10-19-007-function-values.md`

## Summary

File-level and module-qualified functions are values with nominal function
types that keep their full call signatures, any expression of function type
can be called, and a local that hides a declaration is called as a value.
Equality, printing, formatting, and `isinstance` reject function values. The
plan's goal is met.

## Departures from the plan

- `parse_assignment_or_call` also accepts `CallValue` as a statement, so
  `(f)(x)` on its own line is a call rather than "only calls can be used as
  statements".
- Bind tests that expected "cannot call local variable" now check that such
  calls become `CallValue`; a non-callable local is reported by check as
  "cannot call a value of type int".

## Decisions

- Every non-import declaration now gets a `type_name`, not only records,
  enums, and aliases, so function types are named `function add` or
  `function app.util.make`.

## Checks run

- `make test` — 288 passed, 0 failed.

## Manual verification

1. `tests/programs/function_values.out` was read against the program: the
   callee prints `callee` before its argument prints `arg`, and the hidden
   `double` calls `add`.

   ```sh
   ./willow run tests/programs/function_values.wlo
   ```
