# Callable type syntax

## Plan

`agents/plans/2026-10-19-017-callable-type-syntax.md`

## Summary

Annotations use `(A, B, ...) -> R`, parentheses group types, diagnostics name
callables in that syntax with union members parenthesized, and the `typing`
module is gone. Tests and the three Rosetta examples use the new syntax. The
plan's goal is met.

## Departures from the plan

- `tuple[...]` read a leading `(` as the start of `tuple[()]`, so
  `tuple[(int) -> int, int]` failed to parse. The tuple branch now treats `()`
  as the empty tuple only when `]` follows it. A parser test covers
  `tuple[() -> int, int]`.
- The bind test for a stale `typing` annotation uses `typing.Callable` without
  arguments, because the parser now rejects `[[` in type arguments before bind
  runs. It reports `unknown module 'typing'`. `import typing` itself reports the
  loader's `cannot load module 'typing'` error.

## Checks run

- `make test` — 318 passed, 0 failed.

## Manual verification

1. The Rosetta examples that used `typing` still run.

   ```sh
   for f in closures_value_capture parametric_polymorphism higher_order_functions; do ./willow run examples/rosettacode/$f.wlo; done
   ```

   Each exits 0 with its usual output.

2. `import typing` is rejected.

   ```sh
   printf 'import typing\n\ndef main() -> None:\n    pass\n' > /tmp/main.wlo && ./willow run /tmp/main.wlo
   ```

   `main.wlo:1:8: error: cannot load module 'typing': typing.wlo: No such file or directory`
