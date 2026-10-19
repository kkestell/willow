# Tuple types and values

## Plan

`agents/plans/2026-10-19-002-tuple-types-and-values.md`

## Summary

Tuple types, displays, literal indexing, `len`, positional assignability with
per-position float conversion, one tuple member per union, and
`isinstance(v, tuple)` work as planned. The plan's goal is met.

## Departures from the plan

- `compiler/runtime.lua`: each optional runtime now runs inside a local
  function `__wlo_load` in its `do` block. With the host runtime, the chunk was
  already at LuaJIT's 200-local limit, so adding `__wlo_convert` to the core
  broke every program that uses host helpers. Running each optional file in its
  own function gives it a local limit of its own.
- `compiler/bind.lua`: `isinstance(v, tuple)` and `TupleDisplay` elements also
  needed handling in `resolve_function`, which the plan did not list.

## Checks run

- `make test` — 279 passed, 0 failed.

## Manual verification

1. The generated Lua for `tests/programs/tuples.wlo` builds tuples as
   `{ __wlo_tuple = n, ... }`, reads positions as `t[i]`, lowers `len` to the
   arity after still calling `pair()`, and converts with
   `__wlo_convert(floats, { [1] = { float = "box" } })`.

2. The Rosetta Code examples still match their `.out` files except
   `factorial.wlo` and `fibonacci_sequence.wlo`, which differ in the same way
   without this change.

   ```sh
   for f in examples/rosettacode/*.wlo; do ./willow run "$f" 2>&1 | diff -q - "${f%.wlo}.out" >/dev/null || echo "DIFF $f"; done
   ```

## Follow-up work

- `examples/rosettacode/factorial.wlo` overflows and
  `examples/rosettacode/fibonacci_sequence.wlo` differs from its `.out`; both
  predate this change.
