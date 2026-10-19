# Review of callable types

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-19-008-callable-types.md`: type arguments and `TypeList` in the parser, the provided `typing` module, `typing.Callable` resolution and errors in bind, callable types in `same`, `assignable`, and `conflict`, callable callees in `CallValue`, adapters in lowering, emission, and `__wlo_convert`, and the new tests. Callers were traced through `bind_args`, `lower_args`, `convert`, `step_text`, lazy list and dict element types, union narrowing, and the equality, printing, formatting, sorting, and dictionary-key checks. The work was reviewed against the plan and spec §3 Annotations, §4 Assignability and Unions, §5 Function values, and §14 `typing`.

Gaps:

- Bound methods, built-in and library functions as values, nested `def`, closures, `nonlocal`, lambdas, generics, and the rest of `typing` are later tasks and were not reviewed.

## Summary

| ID | Severity | Category | Fix   | Title                                                       |
| -- | -------- | -------- | ----- | ----------------------------------------------------------- |
| F1 | Low      | Comments | Fixed | `types.conflict` comment omits callables                    |
| F2 | Low      | Comments | Fixed | `stdlib.provided` comment omits `typing.Callable`           |

## F1. `types.conflict` comment omits callables

Low · Comments · Fixed · `compiler/types.lua:286`

The comment said lists, dicts, and tuples are counted before overlap is tested. Callables are now counted the same way, so their parameter and result types are never compared.

### Fix

The comment now names callables.

## F2. `stdlib.provided` comment omits `typing.Callable`

Low · Comments · Fixed · `compiler/stdlib.lua:76`

The comment said `records` holds records and aliases. The `typing` module puts the `Callable` type form there too.

### Fix

The comment now says `records` holds records, aliases, and type forms.

## Checks run

- `make test`: 292 passed, 0 failed, before the fixes. The fixes change only comments.
- Programs run with `willow run` covered these cases, and each behaved as specified: aliases of callable types, callable returns, record fields, dict values, and tuple positions; adapted enum, tuple, negative, float, and string defaults across modules; nested callable parameters that need boxing; `int | Callable` narrowing with `isinstance`; `None`-returning callables; tracebacks through an adapter; and the rejection of equality, `in`, formatting, `str`, sorting, dict keys, `except typing.Callable`, malformed `Callable` arguments, and self-referential callable aliases.
- `willow compile` output, run with LuaJIT, was checked for adapters that box or unbox arguments and results.

## Verdict

The implementation meets the plan and spec. It needed only the two comment fixes, F1 and F2.
