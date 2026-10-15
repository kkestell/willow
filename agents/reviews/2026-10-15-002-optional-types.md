# Review: Optional types

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-15-002-optional-types.md` against `willow.md` §14 and `AGENTS.md`: `compiler/lexer.lua`, `compiler/parser.lua`, `compiler/bind.lua`, `compiler/check.lua`, `compiler/lower.lua`, `runtime/core.lua`, the unit and program tests, and `agents/todo.md`. Also read the code that consumes the new `Is` node and the flow state: `lower_operand`, `lower_short_circuit`, `is_pure`, and the `print` builtin path. The `bind.lua` change, which the plan did not list, resolves names inside `Is` operands and is required. No other pass walks expression nodes.

The `todo.md` test item for field and index expressions that do not narrow moves to §15 and §16, matching the plan's test scope.

## Fixed

- **`|` after `is None` gave a generic parse error** (`compiler/parser.lua:203`): `x = a is None | b` reported `expected end of line, found '|'` instead of the §4 unsupported-operator error, because the `|` check ran only after `parse_sum` operands and the `None` after `is` is consumed directly. The check is now a `reject_bitwise_or` helper that also runs after `is None` and `is not None`, so the source reports `unsupported operator '|'`. Added a parser test.

## Findings

No open findings.

## Checks run

- `make test`: `106 passed, 0 failed`, before and after the fix.
- Ran scratch programs: `x = a is None | a` (gave the generic error before the fix and `unsupported operator '|'` after); a `while a is not None` loop whose body assigns `a` in both branches of an `if` (runs and prints `2`, `3`, `4`, `None`); `float | None` equality and printing.
- Ran every program in `examples/`: all succeed.

## Verdict

The milestone meets §14. Annotations, assignability, `is` typing, equality, narrowing through conditions, `if` joins, assignments, and loops, and the lowering and printing of optionals all match the specification. One low-severity diagnostic issue was fixed, and no findings remain open.
