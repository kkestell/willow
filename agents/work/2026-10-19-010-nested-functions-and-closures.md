# Nested functions and closures

## Plan

`agents/plans/2026-10-19-010-nested-functions-and-closures.md`

## Summary

Nested `def` statements bind their names when they run and compile to Lua
closures over the enclosing function's locals. Captures must be definitely
assigned at creation, except the function's own name. Captured variables start
closure bodies with their full types and lose narrowing after every call.
Traceback frames are named `outer.inner`. The plan's goal is met.

## Departures from the plan

- `collect_symbols` sets the scope's fallback metatable after collecting, so
  plain indexing already sees only the function's own names and no `rawget`
  is needed.
- `resolve_function` calls `force_pending` after a nested signature so lazy
  list and dict types are resolved before `check_default` compares them.
- `parse_function` is forward-declared so `parse_statement` can call it.

## Checks run

- `make test` — 299 passed, 0 failed.

## Manual verification

1. `tests/programs/closures.out` was read against the program: `make_counter`
   closures read the rebinding made after them (`11`, `15`), loop closures all
   print `2`, and a closure in a method reads `self`.

   ```sh
   ./willow run tests/programs/closures.wlo
   cd tests/programs && ../../willow run closure_traceback.wlo
   ```

   The traceback lists `in outer.inner`, then `called from outer`.
