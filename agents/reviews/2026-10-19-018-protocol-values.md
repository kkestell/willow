# Review of protocol values

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-19-018-protocol-values.md`: the protocol branch of
`MethodCall` in `compiler/check.lua`; `match`, `converts`, `representable`, and
the `generic` flags in `compiler/types.lua`; protocol call lowering,
`converters`, and table construction in `compiler/lower.lua`; protocol tables,
`Dispatch`, and `Converter` emission in `compiler/emit.lua`; the omitted-argument
marker in `runtime/core.lua`; and the program and unit tests. The change was
checked against `docs/spec.md` §3 Protocols and the plan. The plan's
representation restriction on protocol satisfaction is an accepted departure
from the spec and was reviewed only for soundness.

Small programs exercised implementation defaults of a different representation,
protocol calls inside lambdas and nested functions, and classes whose
same-named methods do not satisfy a called protocol.

Gaps:

- Protocol bounds on type parameters belong to the next task and were not
  exercised.

## Summary

| ID | Severity | Category    | Fix   | Title                                                         |
| -- | -------- | ----------- | ----- | ------------------------------------------------------------- |
| F1 | High     | Correctness | Fixed | Protocol calls in lambdas and nested functions crash lowering |
| F2 | Medium   | Correctness | Fixed | Implementation default passes through the protocol's type     |
| F3 | Medium   | Correctness | Fixed | Converters for non-satisfying types can crash lowering        |

## F1. Protocol calls in lambdas and nested functions crash lowering

High · Correctness · Fixed · `compiler/lower.lua:432`, `compiler/lower.lua:596`

`lower_function` gained a `protocols` parameter, but the `Lambda` expression and
nested `def` statement still called it with three arguments. Any protocol method
call inside a lambda or nested function indexed a nil `protocols` and stopped
compilation with an internal compiler error.

### Evidence

`f = lambda: a.area()` with `a: Area` failed with
`lower.lua:487: attempt to index upvalue 'protocols' (a nil value)`.

### Fix

Both calls pass `protocols`. `tests/programs/protocols.wlo` calls through a
protocol from a lambda and from a nested function.

## F2. Implementation default passes through the protocol's type

Medium · Correctness · Fixed · `compiler/lower.lua:800`

A converter lowered the implementation's default as a value of the protocol
parameter's type, substituted it for the omitted marker, and then converted the
result to the implementation parameter's type. When the implementation's
parameter is wider, the default is not a value of the protocol's type, and the
round trip changes it. With protocol `scale(self, by: float = 1.0)` and an
implementation `scale(self, by: int | float = 3)`, `s.scale()` boxed `3` as a
float, so the implementation saw `isinstance(by, float)` true.

### Evidence

The program above printed `float 3.0` through the protocol and `int 3` through a
direct call.

### Fix

The default is lowered as a value of the implementation parameter's type and is
not converted. A converter now begins with a statement for each defaulted
parameter: `if p == __wlo_omitted then p = <default> else p = <converted p> end`,
with the `else` branch only when the argument needs conversion. `__wlo_given` is
removed from `runtime/core.lua`. `protocols.wlo` covers the case through
`Scaler.scale()`.

## F3. Converters for non-satisfying types can crash lowering

Medium · Correctness · Fixed · `compiler/lower.lua:790`

Entries are built for every class and native type whose method names and
parameters line up with a called protocol, including types whose method types do
not satisfy it. Conversion between unrelated types is undefined. A tuple result
longer than the protocol's reached `conversion(element, nil)` and crashed the
compiler, even though the program never converts that class to the protocol.

### Evidence

A program with protocol `pair(self) -> tuple[int]`, a satisfying class, and an
unrelated class with `pair(self) -> tuple[int, float]` failed in
`types.lua:119: attempt to index local 't' (a nil value)`.

### Fix

`converters` returns nil when a parameter or result whose declared types mention
no type parameter is not assignable. At those positions the declared types are
the substituted ones, so every type that satisfies some specialization of the
protocol still gets its entry. `protocols.wlo` includes such an unrelated class.

## Checks run

- Reproduction programs for F1, F2, and F3 before and after the fixes.
- `./willow run tests/programs/protocols.wlo` and inspection of the generated
  converters.
- `make test`: 319 passed, 0 failed.

## Verdict

The dispatch design, satisfaction restriction, and call lowering are sound. F1
and F3 were compiler crashes and F2 a wrong default representation; all are
fixed with regression coverage in `tests/programs/protocols.wlo`.
