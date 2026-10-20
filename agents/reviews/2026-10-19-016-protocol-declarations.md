# Review of protocol declarations and satisfaction

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-19-016-protocol-declarations.md`: the `protocol` keyword
and `parse_protocol`; bind's protocol declarations, signatures, name
resolution, call, value, `isinstance`, and `except` errors, and the queued
union overlap checks; `types.protocol`, `generic_decl`, `method`,
`compatible`, `satisfies`, and the protocol cases in `same`, `key`,
`conflict`, `record_map`, `substitute`, and `assignable`; check's protocol
inference in `collect` and the interim `MethodCall` error; lowering's
conversions for values that flow through protocol types; the tests; and the
spec and todo changes. Small programs exercised module-qualified protocols,
generic and self-referential protocols against generic classes, protocol to
protocol assignability, union sources, built-in exception sources, unions with
a protocol member in field types and aliases, run-time `isinstance` on unions
with protocol members, and list invariance.

The `(A, B) -> R` callable syntax, the removal of `typing`, the built-in
standard protocols, and the reserved standard protocol names are specified now
and implemented by later todo tasks, so the code still uses `typing.Callable`.
The interim error for method calls on protocol values is intended until the
protocol values task.

Gaps:

- Run-time dispatch through protocol values is the next task and was not
  reviewed.

## Summary

| ID | Severity | Category      | Fix   | Title                                            |
| -- | -------- | ------------- | ----- | ------------------------------------------------ |
| F1 | Low      | Documentation | Fixed | Spec naming rule contradicts the `None` type name |

## F1. Spec naming rule contradicts the `None` type name

Low · Documentation · Fixed · `docs/spec.md:390`

The new rule in §4 said that built-in value types have lowercase names. The
table directly above it lists `None`, a built-in value type with a capitalized
name, so the rule as written was false.

### Fix

The rule now reads "Built-in value types other than `None` have lowercase
names." This needed no decision: `None` is already specified, and the rule is
there to separate value types from classes, protocols, and enums.

## Checks run

- `make test` on the staged change: 318 passed, 0 failed.
- Probe programs with `./willow run` for the cases listed under scope. Each
  one compiled, ran, or reported the expected diagnostic.
- Inspected the spec diff after the fix.

## Verdict

The protocol implementation follows the plan and the spec, and none of the
probes found a defect. The only finding, F1, was an inaccurate sentence in the
spec, now fixed.
