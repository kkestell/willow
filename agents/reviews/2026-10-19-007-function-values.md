# Review of declared functions as values

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-19-007-function-values.md`: function types in `compiler/types.lua`, `CallValue` parsing, `FunctionValue` and `CallValue` binding, checking, lowering, and emission, and the new and updated tests. Callers of the changed paths were traced through `bind_args`, `lower_args`, `is_pure`, `function_name`, and module-qualified calls. The work was reviewed against the plan and spec §5 "Function values and lambdas".

Gaps:

- `typing.Callable`, bound methods, built-in function values, nested `def`, closures, `nonlocal`, and lambdas are later tasks and were not reviewed.

## Summary

| ID | Severity | Category       | Fix   | Title                                                         |
| -- | -------- | -------------- | ----- | ------------------------------------------------------------- |
| F1 | High     | Correctness    | Fixed | A qualified function value resolves to a hiding local         |
| F2 | Low      | Error handling | Fixed | A standard-library function as a value is called a "builtin"  |

## F1. A qualified function value resolves to a hiding local

High · Correctness · Fixed · `compiler/emit.lua:198`

When the entry module imports itself and a function has a local with the same name as one of the module's functions, `prog.add` as a value was emitted as the bare Lua name `add`. That name is the local, so the value was the local's value. Calling it failed at runtime. Qualified calls already avoid this with `qualified`, which makes `function_name` use the module table. Function values did not pass that flag.

### Evidence

```python
import prog

def add(a: int) -> int:
    return a + 1

def main() -> None:
    add = 5
    f = prog.add
    print(f(1))
```

`willow run prog.wlo` failed with `attempt to call local 'f' (a number value)`.

### Fix

`declared_value` in `compiler/bind.lua` marks a `FunctionValue` built from a module-qualified `Field` as `qualified`. Lowering keeps the flag, and `emit` passes it to `function_name`. `tests/programs/function_values.wlo` now imports itself and calls `function_values.double` through a value inside `hidden`, where a local `double` hides the declaration.

## F2. A standard-library function as a value is called a "builtin"

Low · Error handling · Fixed · `compiler/bind.lua:241`

`f = time.time` reported "builtin 'time.time' cannot be used as a value", because `declared_value` used the declaration's internal kind as the noun. Other built-in functions use "function" in this message.

### Fix

`declared_value` reports "function 'time.time' cannot be used as a value" for `Builtin` declarations. A case was added to the `function_values` test in `tests/unit/bind_test.lua`.

## Checks run

- A reproduction of F1 failed before the fix and printed the expected values after it.
- `willow run` on `f = time.time` showed the F2 message before and after the fix.
- `make test`: 288 passed, 0 failed.

## Verdict

The implementation follows the plan. F1 was a miscompilation of self-importing entry modules and F2 was an unclear diagnostic. Both are fixed and covered by tests.
