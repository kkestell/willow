# JSON integer range

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-008-json-integer-range.md`:
`__wlo_json_number` in `runtime/json.lua` and its use of `__wlo_json_error`
and `__wlo_MAX_INT`, the new cases in `tests/programs/json_library.wlo` and
`.out`, the work log, and the `agents/todo.md` update. The review read them
against spec §14 `json`.

Gaps:

- None material.

## Summary

No findings.

## Checks run

- A scratch program parsed a 300-digit integer (`tonumber` gives infinity),
  `-9007199254740991`, `[9007199254740993 x]`, `{"é": 9007199254740992}`,
  `-0`, and `1e400`. The out-of-range tokens reported `integer out of range` at
  the token's first character, with the column counted in code points; the
  range error came before the later trailing-text error; the other values
  parsed as before.
- `make test` before staging: 336 passed, 0 failed (from the work log; no
  code changed during the review).

## Verdict

`json.parse` now matches spec §14: integer tokens outside the `int` range raise
`JsonError` `integer out of range` at the token's start, and numbers with a
fraction or exponent still become floats. The tests cover the top-level,
array, and multi-line object positions.
