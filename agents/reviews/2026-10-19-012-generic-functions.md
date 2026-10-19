# Generic functions with explicit specialization

## Scope and coverage

Reviewed the staged implementation of
`agents/plans/2026-10-19-012-generic-functions.md`: the parser's type
parameter lists and `SpecializedCall`, bind's type parameter scope, lazy scope
capture, union and `isinstance` rules and call resolution, `types.substitute`,
check's specialized `Call` and `CallValue`, and the new tests. Reviewed against
spec §3 (Type parameters) and §4 (Unions). Probed opaque type parameter
operations, float representation across specialized calls and callables,
nested and recursive generics, index calls that look like specializations, and
calls across modules.

Gaps:

- Inference, generic classes and methods, aliases, bounds, and generic function
  values are later tasks and were not reviewed.

## Summary

| ID | Severity | Category       | Fix   | Title                                                   |
| -- | -------- | -------------- | ----- | ------------------------------------------------------- |
| F1 | Medium   | Correctness    | Fixed | Generic functions cannot be called from another module   |
| F2 | Low      | Error handling | Fixed | Specializing a built-in reports a misleading error       |
| F3 | Low      | Comments       | Fixed | Two doc comments sit above the wrong function            |

## F1. Generic functions cannot be called from another module

Medium · Correctness · Fixed · `compiler/parser.lua:308`, `compiler/bind.lua:460`

The parser tried `[types](` only after a bare `Name`, so `util.first[int](xs)`
parsed as an index of `util.first`. Bind then reported "generic function
'util.first' cannot be used as a value", and calling it without type arguments
reports "'util.first' needs type arguments". A generic file-level function was
unusable outside its own module.

### Evidence

A two-module program calling `util.first[int]([1, 2])` failed with
"generic function 'util.first' cannot be used as a value".

### Fix

The parser also tries a specialized call after a `Field`. Bind resolves a
`SpecializedCall` whose callee is a module-qualified name through `lookup`,
turning it into a `Call` named `path.name`; any other field callee, such as
`h.handlers[i](x)`, still becomes an index call. The `Call` branch keeps a
target that is already set. Added `app.deep.leaf.wrap[str](...)` to
`tests/modules/qualified` and a parser case for `util.first[int](xs)`.

## F2. Specializing a built-in reports a misleading error

Low · Error handling · Fixed · `compiler/bind.lua:460`

`len[int](xs)` fell through to the index-call path because only declarations,
not built-ins, were treated as non-generic callees, and reported
"function 'len' needs an expected callable type".

### Fix

Built-in names count as declarations there, so it reports "'len' is not
generic". Added a bind test.

## F3. Two doc comments sit above the wrong function

Low · Comments · Fixed · `compiler/bind.lua:338`, `compiler/parser.lua:289`

The new `enter_type_params` was inserted below `resolve_signature`'s doc
comment, and `parse_specialized_call` below `parse_postfix`'s, so each
function carried two comments, one describing another function.

### Fix

Moved each comment back above the function it describes.

## Checks run

- Probe programs for opaque `T` operations (truthiness, formatting, `str`,
  `in`, list methods, sorting, equality, dict keys, `is None`, `isinstance`),
  float values through `float`, `int | float`, tuple, and callable type
  arguments, nested and recursive generics, and index calls through locals,
  fields, enums, and strings: all behaved as specified.
- `make test`: 307 passed, 0 failed.

## Verdict

The implementation meets the plan once F1 lets other modules call generic
functions. F2 and F3 were minor cleanups. All findings are fixed.
