# Tuple types and values

## Scope and coverage

Reviewed the staged implementation of
`agents/plans/2026-10-19-002-tuple-types-and-values.md`: the `tuple` keyword,
tuple type and display parsing, tuple resolution in `compiler/bind.lua`,
`types.tuple` and the tuple cases of `same`, `assignable`, and `conflict`, the
tuple `Index`, `len`, `TupleDisplay`, and `IndexAssign` checks,
`conversion`, `convert`, and the `Tuple` and `Position` lowerings,
the new emit cases, `__wlo_convert` and the tuple test in `__wlo_isinstance`,
the `compiler/runtime.lua` change that runs each optional runtime in its own
function, the `agents/todo.md` edit, and the new tests. Traced per-position
float conversion through boxed unions, optionals, nested tuples, and list
displays, against spec §3, §4, and §7.

Gaps:

- None material. `examples/rosettacode/factorial.wlo` and
  `fibonacci_sequence.wlo` already fail before this change and were not
  reviewed.

## Summary

| ID | Severity | Category    | Fix   | Title                                                   |
| -- | -------- | ----------- | ----- | ------------------------------------------------------- |
| F1 | High     | Correctness | Fixed | Tuple types inside `list` and `dict` are unknown types |

## F1. Tuple types inside `list` and `dict` are unknown types

High · Correctness · Fixed · `compiler/bind.lua:93`

A `list` element or `dict` value type is lazy, and `lazy` names it with
`type_text`. `type_text` had no `tuple` case, so it fell through to
`resolve_named` and reported "unknown type 'tuple'". Every annotation such as
`list[tuple[int, str]]` or `dict[str, tuple[int, str]]` was rejected.

### Evidence

`xs: list[tuple[int | float]] = [t, (3,)]` and
`d: dict[str, tuple[int, str]] = {"a": (1, "x")}` both failed with
"unknown type 'tuple'". The new bind test fails without the fix.

### Fix

Added a `tuple` case to `type_text` that names the type the way `types.tuple`
does, including `tuple[()]`. Added a `list[tuple[int, tuple[()]]]` case to the
`tuples` test in `tests/unit/bind_test.lua`.

## Checks run

- `make test`: 279 passed, 0 failed, before and after the fix.
- Ran scratch programs covering `==`, `for`, `str`, and `print` on tuples,
  which are rejected; out-of-range and non-literal indexes; indexing displays
  and call results; `len` of displays with calls; `isinstance` on
  `int | tuple[int]`; tuple aliases and class fields; and float conversion
  through `tuple[float]` to `tuple[int | float]`, nested tuples, optionals,
  boxed unions, and lists of tuples. Output was as expected after the fix.
- Loaded the runtime with every optional runtime included to confirm the
  per-file functions stay within LuaJIT's limits.

## Verdict

The implementation matches the plan and the spec apart from F1, which is
fixed.
