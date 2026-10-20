# Review of callable type syntax

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-19-017-callable-type-syntax.md`: `parse_parenthesized`,
the `(` branch in `parse_member`, the `tuple[()]` lookahead, and plain
named-type arguments in the parser; bind's `type_text`, `resolve_type`,
`resolve_named`, `CANNOT_CALL`, and `isinstance` changes; the callable and
union names in `types.lua`; the removal of the `typing` module; the unit,
program, and Rosetta example updates; and the work log and todo entry. The
change was checked against `docs/spec.md` §3, including the speculative type
parse in `parse_specialized`, which now also accepts parenthesized types such
as `xs[(i)]`.

Small programs exercised callables as list, dict, and tuple elements, union
members with and without parentheses, nested and right-associated callables,
callable parameters of callables, trailing commas, grouping such as `((int))`,
`tuple[()]` beside `tuple[() -> int]`, an alias that expands to itself through
a callable parameter, an alias reached through `list[...]` in a callable
result, `(int, str)` without `->`, and indexing written `xs[(i)]`.

Gaps:

- None material.

## Summary

| ID | Severity | Category | Fix   | Title                                      |
| -- | -------- | -------- | ----- | ------------------------------------------ |
| F1 | Low      | Comments | Fixed | `resolve_named` comment was left unwrapped |

## F1. `resolve_named` comment was left unwrapped

Low · Comments · Fixed · `compiler/bind.lua:85`

Removing `typing.Callable` from the `resolve_named` comment left its second
line at 105 columns, the only comment line in the compiler over 100 columns.

### Fix

Rewrapped the comment to the surrounding width. The text is unchanged.

## Checks run

- `make test` on the staged change before review: 318 passed, 0 failed.
- Probe programs with `./willow run` for the cases listed under scope. Each
  parsed, ran, or reported the expected diagnostic, and diagnostics named
  callables as `(A, B) -> R` with callable union members parenthesized.
- Searched the repository outside `agents/` for `typing`, `Callable`, and
  `TypeList`; no stale uses remain.
- Inspected the diff of the comment fix.

## Verdict

The change implements the specified callable syntax and display names, removes
`typing` and the `TypeList` node cleanly, and keeps callable semantics and
program output unchanged. The only finding, F1, was a comment wrap and is
fixed.
