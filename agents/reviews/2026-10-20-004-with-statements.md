# `with` statements review

## Scope and coverage

Reviewed the staged `with` statement change against
`agents/plans/2026-10-20-004-with-statements.md` and spec §3 Standard protocols
and §8 Scoped cleanup: the parser, `ast.assignments`, bind, check, lower, emit,
the unit tests, `tests/programs/with_statements.wlo` and `.out`, the work log,
and the `todo.md` update. The `Try` emission and `__wlo_try` departures that
`lower_with` relies on were traced through the generated Lua. Scratch programs
covered a `ContextManager[T]` protocol value, a bounded type parameter, a
generic class manager, a generator manager closed after `break`, a generator
iterated to the end inside `with`, nested `with` statements with `return` in a
loop, `continue` from `with` in `while`, a later manager's expression reading an
earlier target, a nested function using `with` inside `with`, and a bare
`raise` inside `with` in an `except` clause.

Gaps:

- Method calls on native receivers lower through `node.object.type`, which the
  synthesized `ManagerRef` does not carry. No native type has `enter`/`exit`
  yet; the library-resources task adds them and exercises that path.

## Summary

| ID | Severity | Category    | Fix   | Title                                           |
| -- | -------- | ----------- | ----- | ----------------------------------------------- |
| F1 | Low      | Readability | Fixed | Each `with` item claims a new manager local     |
| F2 | Low      | Readability | Fixed | A name target goes through a needless temporary |

## F1. Each `with` item claims a new manager local

Low · Readability · Fixed · `compiler/lower.lua:661`

`lower_with` numbered managers with a running count, so every `with` item in a
function declared another `__wlo_m<i>` local, even when the earlier statement
had already exited. `main` in `tests/programs/with_statements.wlo` declared
`__wlo_m1` through `__wlo_m9`. Temporaries number by depth for the same reason:
the generated Lua stays readable and the function stays well under LuaJIT's
200-local limit.

### Fix

Managers are numbered by nesting depth: `active` counts the managers entered
around the statement being lowered, and `managers` keeps the maximum for
`function_body`. Sequential statements reuse `__wlo_m1`; `main` now declares
`__wlo_m1` and `__wlo_m2`.

## F2. A name target goes through a needless temporary

Low · Readability · Fixed · `compiler/lower.lua:668`

The `enter` result was always spilled to a temporary before the target was
assigned, producing `__wlo_t1 = R.enter(__wlo_m1)` followed by `a = __wlo_t1`.
Only a tuple pattern reads the value more than once.

### Fix

A name target is assigned the `enter` call directly; a tuple pattern still reads
it from a temporary.

## Checks run

- Scratch programs listed above: output matched spec §8 before and after the
  fixes.
- `willow compile tests/programs/with_statements.wlo`: generated Lua inspected
  for manager locals, target assignment, and exit arguments.
- `make test`: 332 passed, 0 failed.

## Verdict

The change implements spec §8 scoped cleanup as planned: entry order, exit
order after a failed entry, the pending error or `None` on every departure,
exit errors replacing the pending exception or transfer, and generator closing
all behave correctly. F1 and F2 tidied the generated Lua.
