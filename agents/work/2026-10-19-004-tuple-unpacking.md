# Tuple unpacking

## Plan

`agents/plans/2026-10-19-004-tuple-unpacking.md`

## Summary

Assignment and `for` targets accept name and nested tuple patterns with static
shape checks, duplicate and starred targets are rejected, and
`fibonacci_sequence.wlo` steps with tuple assignment. The plan's goal is met.

## Departures from the plan

- The lowering helper is `unpack_pattern` rather than `unpack`, so it does not
  shadow Lua's `unpack`.

## Decisions

- A target can be the source local only when that local has a union type that
  holds both the tuple and its position's type; `tests/programs/unpacking.wlo`
  covers that case with `v: tuple[int, int] | int`.
- `for k, v in d` now parses, so the old `for_loops` parser test that expected
  "expected 'in', found ','" checks a missing `in` instead.

## Checks run

- `make test` — 284 passed, 0 failed.

## Manual verification

1. The Fibonacci example matches its updated output, and fib(78) is the
   largest Fibonacci number at most `2^53 - 1`.

   ```sh
   ./willow run examples/rosettacode/fibonacci_sequence.wlo | diff - examples/rosettacode/fibonacci_sequence.out
   vendor/luajit/src/luajit -e 'local a,b=0,1 for i=1,79 do a,b=b,a+b end print(a > 2^53-1, b)'
   ```

   No diff; fib(79) exceeds the limit.

## Follow-up work

- `examples/rosettacode/factorial.wlo` prints `factorial_recursive(20)`, which
  overflows Willow's integer range, so it does not match its `.out`.
