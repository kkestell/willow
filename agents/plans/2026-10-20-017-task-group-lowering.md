# Task group lowering and protected cleanup

## Goal

Make task groups run (spec §15), using the runtime from plan 016:

- `async with` enters its group, runs the body, and joins at the boundary.
  The group's exit may replace the body's departure with its failure or an
  outer request, or absorb its own stop.
- In async functions, `finally` clauses and resource exits run protected from
  cancellation that originates in enclosing scopes.
- `aio.task_group()` creates a group, and the interim
  `task groups are not implemented yet` diagnostic is removed.

## Related code

- `runtime/aio.lua` (agent loop): `aio_task_group`, `aio_group_enter`,
  `aio_group_exit(g, code, value)`, `aio_scope`, `aio_set_scope`, and the
  method helpers already named by plan 015.
- `compiler/lower.lua`: `lower_with`, `protect`, `resume`, Try nodes.
- `compiler/emit.lua`: Try emission.

## Decisions

- **Group.** `lower_group` stores the group in a manager local, calls
  `aio_group_enter(m)`, assigns the `as` name, and lowers the body as a Try
  with no handlers or `finally`. Its `exit` is
  `aio_group_exit(m, code, value)`, which emission assigns back to the Try's
  code and value. The usual tail then raises `raise` and `cancel` again and
  resumes `return`, `break`, and `continue`. A nil code continues after the
  statement.
- **Protection.** Try nodes in async functions, including `with` exits and
  excluding group Trys, are marked `protect`. Their emission saves
  `aio_scope()` before `__wlo_try`, restores it right after when there are
  handlers, sets it to nil before the `finally` block, and restores it after.
  A `finally` that raises skips its own restore, and the nearest enclosing
  Try with handlers, or a group exit, repairs it. This is loop's sequence.
- **Bundling.** An async function marks `aio_scope` and `aio_set_scope`
  used, so `runtime/aio.lua` is included. `aio.task_group` lowers to
  `aio_task_group`.

## Test plan

- `tests/programs/task_groups.wlo`: the §15 example; ready order; `cancel()`
  absorbed, with awaiting cleanup that only protection lets finish; a
  cancelled handle's `result()`; `cancel` on an exited group; a stop during a
  join keeping a pending return; nested groups with an outer request; failure
  precedence over an outer request, caught and uncaught; re-entry, closed
  admission without consuming, and `task is not finished`.
- `tests/programs/task_group_failure.wlo`: a child failure propagates after a
  sibling's cleanup, with a traceback ending `in task started at`.
- `tests/programs/task_group_deadlock.wlo`: the prototype's self-await,
  reported as `error: deadlock: all tasks are waiting`.
- `tests/programs/task_group_cleanup.wlo`: the prototype's cleanup awaiting a
  task cancelled by the same stop raises `task was cancelled`.
- `tests/programs/task_group_patterns.wlo`: the prototype pipeline, a fan-out
  with a deadline (sleeps in place of TCP), and both retry forms. The
  prototype's `static.wlo` is covered by the check tests from plan 015, and
  `server.wlo` needs async TCP.
- `tests/suites/async` and `tests/unit/cli_test.lua`: async tests with groups,
  one failing in a task.
- `make test` passes.

## Implementation plan

1. Lower `async with`; emit the Try exit.
2. Mark and emit protection; remove the diagnostic.
3. Program and suite tests; tick the items in `agents/todo.md`.
