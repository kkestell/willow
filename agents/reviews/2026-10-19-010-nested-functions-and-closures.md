# Nested functions and closures

## Scope and coverage

Reviewed the staged implementation of
`agents/plans/2026-10-19-010-nested-functions-and-closures.md`: parser, `ast.assignments`,
bind (scope chaining, captures, nested signatures), check (entry states, capture
definite assignment, call-driven narrowing removal), lowering and emission of
closures, and the new tests. Behavior was checked against spec §3 Functions,
§5 Function values, and §9 Scope, Captures, and Narrowing, with probe programs
for loops, `try`, keyword arguments, adapters, labels, `return` in `try`, and
tracebacks through methods and two nesting levels.

Gaps:

- `nonlocal`, lambdas, generators, and `with` are later tasks. Without `nonlocal`,
  no call can yet rebind a captured variable, so the narrowing findings below
  change which programs the checker accepts, not what programs do at run time.

## Summary

| ID | Severity | Category    | Fix   | Title                                                          |
| -- | -------- | ----------- | ----- | -------------------------------------------------------------- |
| F1 | Medium   | Correctness | Fixed | Loops and `try` clauses keep captured narrowing across calls   |
| F2 | Medium   | Correctness | Fixed | Call arguments are checked in parameter order, not written order |
| F3 | Medium   | Correctness | Fixed | Taking a built-in function as a value removes captured narrowing |

## F1. Loops and `try` clauses keep captured narrowing across calls

Medium · Correctness · Fixed · `compiler/check.lua:789`, `compiler/check.lua:993`, `compiler/bind.lua:545`

Spec §9 says every call removes the narrowing of a captured binding. The checker
removed it only after calls in straight-line code. A loop body is checked once
from its entry state, so a later iteration was checked as if no call had run in
an earlier one. `except` and `finally` clauses start from the state before the
`try`, and the state after a `finally` kept narrowing its calls removed. Each of
these programs was accepted although `x` is captured and narrowed only before a
call that precedes the read:

```python
if x is not None:
    for i in range(3):
        print(x + i)      # second iteration follows print()

if x is not None:
    try:
        g()
    except ValueError:
        print(x + 1)      # may start after g()

if x is not None:
    try:
        pass
    finally:
        g()
    print(x + 1)          # follows g()
```

With `nonlocal`, any of them could read `None` as `int`.

### Evidence

Probe programs for `while`, `for`, `except`, and `finally` all passed `willow check`
before the fix.

### Fix

Bind counts the calls each function resolves and marks a `While` (condition or
body) or `For` (body) that contains one with `calls`. The checker removes captured
narrowing at the start of such a loop, next to the existing `forget_narrowing`.
`check_try` uses the checker's call counter: a call in the body removes captured
narrowing from the handler and `finally` entry states, a call in a handler from
the `finally` entry, and a call in the `finally` clause from the state after the
statement. Regression tests in `tests/unit/check_test.lua` `closures` cover a
loop with a call, a loop without one, and an `except` after a call.

## F2. Call arguments are checked in parameter order, not written order

Medium · Correctness · Fixed · `compiler/check.lua:373`

`bind_args` puts arguments in parameter order, and the `Call`, `CallValue`, and
`MethodCall` branches checked them in that order. Lowering evaluates them in
written order (`node.order`). Now that a call in one argument removes captured
narrowing for later ones, the order matters: `k(b=g(), a=x + 1)` was accepted
although `g()` runs before `x + 1`, and `k(b=x + 1, a=g())` was rejected although
`x + 1` runs first.

### Evidence

Both probes behaved as described with a captured `x: int | None` narrowed by
`if x is not None`.

### Fix

Added `evaluation_order(node)`, the written argument indexes followed by
defaulted ones, and used it in the three argument loops. Regression tests cover
both directions.

## F3. Taking a built-in function as a value removes captured narrowing

Medium · Correctness · Fixed · `compiler/check.lua:600`

A `BuiltinValue` is checked by checking a synthetic `Call` of the built-in. That
`Call` went through the common call path, which removed captured narrowing and
counted as a call, although taking the value calls nothing. With `x` captured
and narrowed, `f: typing.Callable[[str], int] = len` followed by `print(h(x))`
reported "expected str, received str | None".

### Fix

The synthetic call is checked against a copy of the state, and the call counter
is restored afterwards. A regression test covers it.

## Checks run

- Probe programs with `willow check` and `willow run` for each finding, before and
  after the fixes, plus closures with defaults through adapters, `continue` labels
  in nested functions, `return` inside `try`, and tracebacks through a method and
  two nesting levels.
- `make test`: 299 passed, 0 failed.

## Verdict

The closure implementation matches the plan: scoping, captures, definite
assignment at creation, Lua upvalue sharing, and frame names behave as specified.
The call-driven narrowing rule had gaps at loop back edges and `try` clauses (F1),
in keyword argument order (F2), and for built-in function values (F3). All three
are fixed with regression tests.
