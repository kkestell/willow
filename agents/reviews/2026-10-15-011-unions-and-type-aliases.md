# Review: unions and type aliases

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-15-011-unions-and-type-aliases.md` against `docs/spec.md` §3, §4, §5, §7, and §9: `compiler/types.lua`, `compiler/parser.lua`, `compiler/bind.lua`, `compiler/check.lua`, `compiler/lower.lua`, `compiler/emit.lua`, `runtime/core.lua`, the new program and module tests, the unit test changes, and `agents/todo.md`. Also read the unchanged code the change depends on: the checker's `try` and flow-state helpers, lowering's `spill`, `set`, `lower_object`, and statement cases, emit's line mapping, and the runtime's dictionary and string helpers.

Gaps:

- Checked on macOS only.

## Summary

| ID | Severity | Category    | Fix            | Title                                                  |
| -- | -------- | ----------- | -------------- | ------------------------------------------------------ |
| F1 | Medium   | Correctness | Fixed          | Substring `in` accepts a non-`str` member and misbehaves |

## F1. Substring `in` accepts a non-`str` member and misbehaves

Medium · Correctness · Fixed · `compiler/check.lua:341`

The `in` rule accepts any printable left operand that is assignable to or from the item type. For a string right operand the item type is `str`, so any union with a `str` member passes, such as `x: int | str`. Lowering then calls `__wlo_str_contains(text, x)`, which passes `x` to Lua's `string.find`. Lua turns a number into its decimal text, so `5 in "a5b"` is `True`. A `None` member raises a raw Lua error instead.

General unions make the wrong `True` reachable for the first time. The `None` crash already happened with `str | None` before this change, and has the same cause.

### Evidence

```python
def f(x: int | str) -> bool:
    return x in "a5b"
def h(x: str | None) -> bool:
    return x in "abc"
def main() -> None:
    print(f(5))
    print(h(None))
```

`willow run` prints `True`, then fails with `bad argument #1 to 'find' (string expected, got nil)` at `h`.

### Fix

Suggested: when the right operand is `str`, require the left operand's type to be `str`. Checking this statically fits the `sub in s` entry in §7 and Python's `TypeError` for a non-string `sub`, and it rejects both cases. The decision is which rule to adopt. The spec does not give the operand type for substring `in`, so the alternatives are this static rule or a runtime result of `False` for non-`str` values.

Fixed: adopted the static rule. When the right operand is `str`, the `in` and
`not in` checks in `compiler/check.lua` require the left operand's type to be
exactly `str`, so `int | str` and `str | None` operands are type errors.
`tests/unit/check_test.lua` covers both.

## Checks run

- `make test`: 196 passed, 0 failed.
- Compiled and ran programs that box and unbox floats through assignment, annotations, list and dict displays, `append`, index and field assignment, constructor arguments, returns, call arguments, `for` items, `dict.get`, narrowed reads, f-strings, `str`, and `print`. Every value printed with its own type's text. `==` and `in` were false across `int` and `float` members and true within one.
- Narrowing programs: `isinstance` and `is None` across `if`/`elif`/`else`, `and`, `or`, and `not`; joins after branches that assign; a `for` loop name; and `try` clauses. Each one checked and ran as §9 describes.
- Structurally equal recursive aliases (`int | list[A]`, `int | list[B]`, and `int | list[int | list[C]]`) assigned to each other in both directions, including inside `list[...]`. Self-expanding and mutual aliases were rejected.
- Diagnostics for `type` inside a function, `isinstance` as a value, a local `isinstance` called, an `isinstance` class outside the operand's type, a module alias used as a value or called, and a union dictionary key.
- Ran `tests/programs/unions.wlo` under Python 3.14. It differs only where §5 makes `int` and `float` members unequal and where Willow records differ from Python classes.

## Verdict

The change implements unions, aliases, `isinstance`, and narrowing as the plan describes. F1 is fixed by requiring a `str` left operand for substring `in`. No findings remain.
