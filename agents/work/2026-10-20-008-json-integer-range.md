# Strict JSON integer range

## Plan

`agents/plans/2026-10-20-008-json-integer-range.md`

## Summary

`json.parse` raises `JsonError` `integer out of range` at the first character of
an integer token outside the `int` range, instead of returning a float. Numbers
with a fraction or exponent still parse as floats. The plan's goal is met, and
`agents/todo.md` has no open items.

## Checks run

- `make test`: 336 passed, 0 failed.
