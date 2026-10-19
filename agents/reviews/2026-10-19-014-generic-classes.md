# Generic classes and methods

## Scope and coverage

Reviewed the staged implementation of
`agents/plans/2026-10-19-014-generic-classes.md`: `parse_type_params` and
`parse_record` in `compiler/parser.lua`; generic class declarations,
annotations, type scopes, and `SpecializedCall` resolution in
`compiler/bind.lua`; `generic`, `record_map`, `same`, `conflict`,
`has_typevar`, and `substitute` in `compiler/types.lua`; `collect`,
`field_type`, constructor `Call`, `MethodCall`, `Field`, and `IsInstance` in
`compiler/check.lua`; and the new tests. Reviewed against spec §3 (Type
parameters) and §4 (Unions). Probed explicit and inferred constructors with
keyword arguments, `int | float` specializations through fields, methods, and
callables, method type parameters on generic and non-generic classes, nested
functions in methods, polymorphic recursion, aliases of specializations,
`isinstance` and `is not None` narrowing, wrong arity, and use across modules.

Gaps:

- Generic aliases, bounds, generic function values, protocols, and explicit
  method specialization (`b.map[int](f)`) are later or deferred work and were
  not reviewed.

## Summary

| ID | Severity | Category       | Fix   | Title                                                   |
| -- | -------- | -------------- | ----- | ------------------------------------------------------- |
| F1 | Low      | Error handling | Fixed | Generic method value on a plain class blames its class  |
| F2 | Low      | Comments       | Fixed | `self` comment moved off `parse_function`               |

## F1. Generic method value on a plain class blames its class

Low · Error handling · Fixed · `compiler/check.lua:835`

Reading a method with its own type parameters as a value reported "methods of
generic classes cannot be used as values" even when the class is not generic,
so the message pointed at the wrong cause.

### Evidence

`f = P(1).pick`, with `class P` non-generic and `def pick[U](self, u: U) -> U`,
reported "methods of generic classes cannot be used as values".

### Fix

A method of a generic class keeps that message; a generic method of any other
class reports "generic method 'pick' cannot be used as a value", matching the
generic function message. `tests/unit/check_test.lua` covers it.

## F2. `self` comment moved off `parse_function`

Low · Comments · Fixed · `compiler/parser.lua:776`

Extracting `parse_type_params` left the comment about a method's `self`
parameter above the new helper, stacked on the helper's own comment.

### Fix

Moved the comment back above `parse_function`.

## Checks run

- Focused `willow run` probes of the cases listed in scope.
- `make test`: 311 passed, 0 failed.

## Verdict

The implementation meets the plan. Types, substitution, and float
representation hold across fields, methods, constructors, and modules. F1 and
F2 were minor and are fixed.
