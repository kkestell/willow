# Callable types

## Plan

`agents/plans/2026-10-19-008-callable-types.md`

## Summary

`import typing` provides `typing.Callable[[A, ...], R]`. Functions and
callables convert to callable types under the planned rules, with adapters
that convert float representations and supply omitted defaults, and calls
through a callable are positional and exact. The plan's goal is met.

## Departures from the plan

- `parse_list` moved above `parse_member` in `compiler/parser.lua` so type
  arguments can use it.

## Checks run

- `make test` — 292 passed, 0 failed.

## Manual verification

1. The generated Lua for `tests/programs/callables.wlo` passes functions that
   need no adapting unchanged (`apply(maybe, 4)`), wraps `add` as
   `__wlo_convert(add, { adapt = function(__wlo_f, __wlo_p1) return __wlo_f(__wlo_p1, 10) end })`,
   and boxes `half`'s result for `typing.Callable[[float], int | float]`.
   The output was read line by line against the program.
