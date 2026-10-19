# Bound methods and built-in function values

## Plan

`agents/plans/2026-10-19-009-bound-methods-and-builtin-values.md`

## Summary

Reading a declared method from a class value gives a bound method that keeps
its receiver and full signature, and built-in and provided-module functions
become values where an expected callable type fixes their signature. The
plan's goal is met.

## Departures from the plan

- `int`, `float`, `str`, and `bytes` are keyword tokens, so the parser now
  reads them as `Name` nodes when no `(` follows; otherwise `str` could not be
  a value. Such names are marked `reserved`, and assigning to one reports
  "cannot assign to 'bytes'" where it used to report "expected an expression".
- The earlier bind test expecting "function 'time.time' cannot be used as a
  value" now checks that `time.time` binds to a `BuiltinValue`.

## Checks run

- `make test` — 294 passed, 0 failed.

## Manual verification

1. `tests/programs/bound_methods.out` was read against the program: `make`
   prints once for three calls through the bound method, the bound method sees
   `c.n = 200`, and `int` as a callable raises `ValueError` with the same
   message as a direct call.

   ```sh
   ./willow run tests/programs/bound_methods.wlo
   ```
