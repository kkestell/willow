# Strict JSON integer range

## Goal

`json.parse` limits integer tokens to the `int` range (spec §14 `json`). A
number token with no fraction or exponent outside that range raises
`JsonError` with the message `integer out of range` and the line and column of
the token's first character. Today such a token becomes a float. Numbers with a
fraction or exponent still become the nearest float.

## Related code

- `runtime/json.lua`: `__wlo_json_number` parses number tokens and boxes
  out-of-range integers as floats; `__wlo_json_error(problem, pos)` builds the
  located message.
- `tests/programs/json_library.wlo` and `.out`: `round_trip("9007199254740992")`
  prints `float 9007199254740992.0`.

## Decisions

- An integer token whose `tonumber` value exceeds `2^53 - 1` in magnitude
  raises the error at the token's start. Every integer above `2^53 - 1` is at
  least `2^53`, which is exact, so rounding cannot bring an out-of-range token
  back into range.

## Test plan

- `tests/programs/json_library.wlo` and `.out`:
  - `9007199254740992` now prints `integer out of range at line 1, column 1`;
  - `[1, -9007199254740992]` reports column 5;
  - an object with an out-of-range value on its second line reports that
    line and the value's column;
  - `9007199254740992.0` and `1e20` still parse as floats, and the existing
    `±9007199254740991` cases as ints.
- `make test` passes.

## Implementation plan

1. Raise the error in `__wlo_json_number`.
2. Update and extend the tests; check off the task and milestone in
   `agents/todo.md`.
