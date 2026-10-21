# Task group front end

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-015-task-group-front-end.md`
(a replay of `ae4221e`): the `aio.task_group`, `aio.TaskGroup`, and
`aio.Task[T]` declarations and generic native methods in
`compiler/stdlib.lua` and `compiler/check.lua`; `await` of a task; `async with`
in `compiler/parser.lua`, `compiler/ast.lua`, `compiler/bind.lua`, and
`compiler/check.lua`; the group frames (`graceful_exit`, `departure`, `mark`,
`since`) and their updates in `check_try`, `With`, loops, `Return`, `Break`,
and `Continue`; the interim lowering diagnostic; and the new tests. The review
read them against spec §9 (definite assignment, control transfer, narrowing,
`try`), §14 `aio`, and §15 (task handles, `await`, task groups, static checking
across a group), and traced `converters` in `compiler/lower.lua`, which reaches
every imported native type.

The §15 static rule was exercised with scratch programs under `willow check`
covering awaits in and around nested groups, `try`/`finally` inside and around
groups (including a `finally` that raises and a group inside a `finally`),
`except` clauses, `with` blocks in group bodies, `break` and `continue` across
groups inside and outside loops, nested async functions, and captured
narrowing. Every result matched the spec.

Gaps:

- Group lowering is the interim diagnostic, so no group program runs. Task and
  group method helpers and `__wlo_aio_await_task` are emitted as references to
  undefined globals; no program can reach them until `aio.task_group()` lowers.

## Summary

| ID | Severity | Category    | Fix  | Title                                                         |
| -- | -------- | ----------- | ---- | ------------------------------------------------------------- |
| F1 | High     | Correctness | Fixed | Importing `aio` crashes lowering of any program with a protocol |

## F1. Importing `aio` crashes lowering of any program with a protocol

High · Correctness · Fixed · `compiler/stdlib.lua:233`, `compiler/lower.lua:899`

`aio.Task` is a hand-built native record with neither `type` nor `self_type`.
`lower` collects every native declaration of every imported module and calls
`converters(protocol, record)` for each protocol in the program, which calls
`types.method(record.self_type or record.type, name)` with `nil`. Any program
that imports `aio` and uses a protocol type, including a standard protocol
such as `Iterable[int]`, fails `willow run`, `compile`, `build`, and `test`
with an internal compiler error. `willow check` does not lower, so it passes.
This is a regression from the slice's base commit, where the same programs
run. `Coroutine` has the same shape but is not a module declaration, so
`converters` does not reach it today.

### Evidence

```python
import aio

def show(xs: Iterable[int]) -> None:
    for x in xs:
        print(x)

async def main() -> None:
    show([1, 2])
```

`willow run` reports
`internal compiler error: compiler/types.lua:291: attempt to index local 't' (a nil value)`
from `converters` in `compiler/lower.lua:899`. The same failure occurs with a
user protocol and class. The base commit, extracted to a scratch directory,
prints `1` and `2`.

### Fix

`compiler/stdlib.lua` gives `aio.Task` and `Coroutine` a self type,
`types.generic(record, { T })`, as `bind.lua` gives generic classes, so
`converters` can look up their methods. `tests/programs/aio_protocols.wlo`
imports `aio`, calls through a synchronous protocol and an async protocol
method, and fails without the fix.

## Checks run

- After the fix, `tests/programs/aio_protocols.wlo` and the reproduction above
  pass; `make test`: 352 passed, 0 failed.

- `make test`: 351 passed, 0 failed.
- Definite assignment: assignments before an await and inside a nested group
  stay definite after the group; assignments after an await, after a nested
  group's exit, or after an inner group left by `break` or `continue` do not; a
  `finally` assignment on the way out counts; awaits inside a `finally`, and
  inside a group entered in a `finally`, do not leave the outer group.
- Control transfer: a return after an await, in a `try` body or an `except`
  clause, leaves the code after the group reachable; with no await the group
  transfers and the next statement is unreachable; a `finally` that raises
  drops the recorded exits; a `with` or `try` whose body transfers still makes
  its next statement unreachable inside the group.
- Narrowing: exit states join the body's; a `finally` assignment on the way
  out reaches the exit state; captured narrowing is lost at awaits, at the
  join, and at a nested `with` exit; loop-body assignments widen exits taken in
  the loop condition.
- Types: `start` inference in generic functions and with expected types,
  `Task` invariance, missing and extra type arguments, `TaskGroup[int]`,
  construction, use as a value, `isinstance(t, aio.Task)`, and task values in
  lists, dictionaries, and generic classes.

## Verdict

The front end and the §15 static rule match the spec and the plan across every
case tried. F1, a lowering crash the new `aio.Task` declaration introduced for
ordinary programs that import `aio` and use protocols, is fixed by giving the
native record its self type.
