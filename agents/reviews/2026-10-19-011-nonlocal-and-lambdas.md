# `nonlocal` and lambdas

## Scope and coverage

Reviewed the staged implementation of
`agents/plans/2026-10-19-011-nonlocal-and-lambdas.md`: parsing of `lambda` and
`nonlocal`, `ast.assignments`, bind (nonlocal symbol mapping, use-before-declaration
errors, captures, lambda functions and frame names), check (lambda targets, arity,
capture definite assignment, result inference, nonlocal assignment types), lowering
and emission of lambda closures, the new tests, and both Rosetta Code examples.
Behavior was checked against spec §3, §5 Function values and lambdas, and §9
Captures and `nonlocal`, with probe programs for narrowing across a nonlocal
rebinding, nonlocal through two nesting levels and on parameters and loop
variables, lambdas in methods, loops, `while` conditions, short-circuit operands,
optional callable targets, and boxed results.

Gaps:

- Generators, `with`, generics, iterators, and `sorted` `key` callbacks are later
  tasks and were not reviewed.

## Summary

| ID | Severity | Category    | Fix   | Title                                                     |
| -- | -------- | ----------- | ----- | --------------------------------------------------------- |
| F1 | Medium   | Correctness | Fixed | Calls in a lambda's body remove captured narrowing        |
| F2 | Medium   | Correctness | Fixed | A lambda parameter list rejects a trailing comma          |

## F1. Calls in a lambda's body remove captured narrowing

Medium · Correctness · Fixed · `compiler/check.lua:611`

The checker counts calls to decide when captured variables lose their narrowing
(after a `try` body with a call, or a right operand of `and`/`or` with a call).
A lambda's body is checked with the enclosing function's counter, so a call
inside the body counted as a call at the point where the lambda is created,
although creating it calls nothing. Valid programs were rejected:

```python
if x is not None:          # x is captured by a nested function
    try:
        h = lambda: g()
    except ValueError:
        print(x + 1)       # rejected: int | None and int
```

### Evidence

The program above failed with `operator '+' cannot be applied to int | None and
int` at the `print` line; the same program with `h = 5` was accepted.

### Fix

The `Lambda` branch restores the call counter after checking the body, as the
`BuiltinValue` branch already does. A regression case was added to the
`closures` check test.

## F2. A lambda parameter list rejects a trailing comma

Medium · Correctness · Fixed · `compiler/parser.lua:415`

Spec §3 says parameter lists may end with a trailing comma. `lambda x,: x`
reported "expected a parameter name, found ':'".

### Fix

The parameter loop stops at `:` after a comma. A parser test case was added.

## Checks run

- Probe programs for the cases in the scope paragraph; all matched the spec apart
  from F1 and F2.
- `make test` after the fixes — 303 passed, 0 failed.

## Verdict

The implementation meets the plan and spec. F1 and F2 were checker and parser
rejections of valid programs, and both are fixed.
