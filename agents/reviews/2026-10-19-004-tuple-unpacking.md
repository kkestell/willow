# Tuple unpacking

## Scope and coverage

Reviewed the staged implementation of
`agents/plans/2026-10-19-004-tuple-unpacking.md`: pattern parsing,
duplicate and starred target checks, and `For` patterns in
`compiler/parser.lua`; pattern targets in `ast.assignments`; target
resolution in `compiler/bind.lua`; `check_pattern` and the `Unpack` and `For`
cases in `compiler/check.lua`; `unpack_pattern`, `Unpack`, and `For` patterns
in `compiler/lower.lua`; the `For` change in `compiler/emit.lua`; the
Fibonacci example; the `agents/todo.md` edit; and the new tests. Traced
symbol collection, narrowing resets, definite assignment, and float boxing
through nested patterns, `for` patterns, parameters as targets, the source
local as a target, and if/else joins, against spec §7 and §8.

Gaps:

- None material. `examples/rosettacode/factorial.wlo` already fails before
  this change and was not reviewed.

## Summary

| ID | Severity | Category   | Fix   | Title                                       |
| -- | -------- | ---------- | ----- | ------------------------------------------- |
| F1 | Low      | Simplicity | Fixed | `check_pattern` stores a type no pass reads |

## F1. `check_pattern` stores a type no pass reads

Low · Simplicity · Fixed · `compiler/check.lua:242`

At a name target, `check_pattern` set `pattern.type`. Lowering passes the
position type to `unpack_pattern` directly, and nothing else reads `.type` on
a pattern target, so the assignment was dead.

### Fix

Removed the assignment.

## Checks run

- `make test`: 284 passed, 0 failed, before and after the fix.
- Focused programs for a parameter as a target, nested `for` patterns that box
  floats into `int | float` locals, a tuple position converted into a
  `tuple[int | float, int]` local, iteration over a tuple of tuples, `continue`
  and `break` in a pattern loop, and narrowing an optional target to `None`:
  all outputs matched Python semantics.
- Diagnostics for use before assignment in the source, a loop target used
  after the loop, a nested shape mismatch, a dictionary iterated with a
  pattern, and retyping a local through a target: as specified.
- Generated Lua for `tests/programs/unpacking.wlo`: one evaluation of each
  source into a temporary, then positional assignments in order.
- Rosetta Code examples against their `.out` files: only `factorial.wlo`
  differs, as before.

## Verdict

The change meets the plan and spec §7 and §8; F1 is fixed.
