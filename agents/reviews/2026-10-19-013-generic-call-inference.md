# Generic call inference

## Scope and coverage

Reviewed the staged implementation of
`agents/plans/2026-10-19-013-generic-call-inference.md`: `types.mentions`,
`collect` and `infer_call` in `compiler/check.lua`, their use in the `Call` and
`CallValue` branches, the `infer_result` path of the `Lambda` branch, and the
new tests. Reviewed against spec §3 (Type parameters) and §4 (Callable types).
Probed keyword and default arguments, recursion and nested generics, generic
function values as arguments, `int` and `float` candidates, optional container
parameters, and lambdas whose callable result the callee fixes.

Gaps:

- Generic classes and methods, generic aliases, bounds, and generic function
  values are later tasks and were not reviewed.

## Summary

| ID | Severity | Category    | Fix   | Title                                                    |
| -- | -------- | ----------- | ----- | -------------------------------------------------------- |
| F1 | Medium   | Correctness | Fixed | `list[T] \| None` parameters infer nothing               |
| F2 | Medium   | Correctness | Fixed | Lambda results the callee fixes lose their expected type |

## F1. `list[T] | None` parameters infer nothing

Medium · Correctness · Fixed · `compiler/check.lua:411`

`collect` matched a union parameter only through a bare type parameter member,
so `T | None` worked but `list[T] | None`, `dict[str, T] | None`, and other
optional containers gave no candidates. A call such as `count([1, 2])` for
`def count[T](xs: list[T] | None)` reported "cannot infer type parameter 'T' of
'count'", although the argument determines `T`.

### Evidence

`willow check` on `opt_list([1])` with `def opt_list[T](x: list[T] | None)`
reported the undetermined-parameter error; `opt_list[int]([1])` checked.

### Fix

The union branch now matches each non-`None` parameter member that is not a
bare type parameter against each non-`None` argument member; `collect` ignores
members of other kinds. `tests/programs/generics.wlo` covers `count([1, 2])`.

## F2. Lambda results the callee fixes lose their expected type

Medium · Correctness · Fixed · `compiler/check.lua:539`

`infer_call` marked every lambda argument whose parameter type mentions a type
parameter as `infer_result`, so its body was checked with no expected type even
when the callable's result mentions none. Bodies that need the expected type,
such as `[v, 1]` for `list[int | None]` or `[]`, then failed, while the same
call with explicit type arguments checked.

### Evidence

For `def app5[T](f: typing.Callable[[T], list[int | None]], x: T)`,
`app5(lambda v: [1], 3)` reported "expected typing.Callable[[int],
list[int | None]], received typing.Callable[[int], list[int]]";
`app5[int](lambda v: [1], 3)` checked.

### Fix

A lambda is marked `infer_result` only when its expected callable's result,
after substituting the candidates chosen so far, still mentions an undetermined
type parameter; otherwise the body is checked against that result.
`tests/programs/generics.wlo` covers `apply_maybe(lambda v: [v, 1], 2)`.

## Checks run

- Focused `willow check` and `willow run` probes of the cases above, before and
  after the fixes.
- `make test`: 307 passed, 0 failed.

## Verdict

The implementation meets the plan. F1 and F2 left valid calls rejected by
inference that explicit type arguments accepted; both are fixed and covered.
