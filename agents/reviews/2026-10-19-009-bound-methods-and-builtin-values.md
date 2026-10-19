# Review of bound methods and built-in function values

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-19-009-bound-methods-and-builtin-values.md`: bound method types and `types.params` in `types.lua`, method `value_type` and `BuiltinValue` binding in bind, bound method `Field` reads, `CallValue` parameters, and the synthetic built-in call in check, `bind`, `BuiltinValue`, and `Typed` lowering and the adapter, `Function` emission, `__wlo_bind` in the runtime, the parser's reading of `int`, `float`, `str`, and `bytes` as names, and the new tests. Callers were traced through `bind_args`, the built-in `Call` checks, `expect_type`, `lower_args`, `convert`, `serves`, and field assignment. The work was reviewed against the plan and spec §5 Function values.

Gaps:

- Nested `def`, closures, `nonlocal`, lambdas, generics, native and collection methods as values, and calling callable fields with `obj.field(x)` are later or out-of-scope work and were not reviewed.

## Summary

| ID | Severity | Category | Fix   | Title                                                      |
| -- | -------- | -------- | ----- | ---------------------------------------------------------- |
| F1 | Low      | Comments | Fixed | `display_member` and `check_expression` comments omit built-in values |

## F1. `display_member` and `check_expression` comments omit built-in values

Low · Comments · Fixed · `compiler/check.lua:138`, `compiler/check.lua:384`

The `display_member` comment listed only the `list`, `dict`, and `tuple` kinds a display takes, and the `check_expression` comment described `expected` only as the type a display takes. A `BuiltinValue` now uses both to find its expected callable type.

### Fix

Both comments now include the `callable` kind and built-in function values.

## Checks run

- `make test`: 294 passed, 0 failed, before the fix. The fix changes only comments.
- Programs run with `willow run` covered these cases, and each behaved as specified: bound methods across modules, through `self` inside a method, on constructed and indexed receivers, in lists built in a loop, in class fields, and with Lua keyword method names; built-in values that box results or convert `int` to `float`, stored in lists, dicts, and tuples, returned from a function, appended, and reassigned; `sorted`, `chr`, `ord`, `bytes`, and `input` as values; tracebacks through a bound method and a built-in value; and the rejection of field assignment to a method, `==` on bound methods, `int += 1`, `for int in`, and a built-in value as a default.
- `willow compile` output was read for `__wlo_bind` calls and built-in `Function` values.

## Verdict

The implementation meets the plan and spec. It needed only the comment fix, F1.
