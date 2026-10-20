# `with` statements

## Plan

`agents/plans/2026-10-20-004-with-statements.md`

## Summary

`with` statements enter managers satisfying `ContextManager[T]` left to right,
assign name and tuple-pattern targets, and exit them right to left exactly
once with the pending exception or `None`. A failed entry, `return` (its value
evaluated first), `break`, `continue`, closing a suspended generator, and an
exception from `exit` all behave as specified. Each manager lowers to a `Try`
whose `finally` calls `exit`, so the existing departure machinery carries every
way out of the body. The plan's goal is met.

## Checks run

- `make test`: 332 passed, 0 failed.

## Manual verification

1. The generated Lua for a `with` around a `return` stores the manager in
   `__wlo_m1`, enters before the protected block, and exits with the pending
   exception before resuming the return.

   ```sh
   ./willow compile tests/programs/with_statements.wlo -o w.lua
   ```

   `returning` reads as planned.
