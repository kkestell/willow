# Task groups and cancellation runtime

## Goal

Add the runtime for task groups, task handles, and cancellation (spec §15) to
`runtime/aio.lua`, tested with Lua unit tests that drive it the way generated
code will. The compiler front end for `async with`, `aio.Task`, and
`aio.TaskGroup` is in plan 015, and the lowering follows it.

## Related code

- `runtime/aio.lua`: the loop, timers, descriptor waits, and wait ids from
  plan 011.
- `runtime/core.lua`: `__wlo_cancel`, `__wlo_try`'s `"cancel"` code,
  `__wlo_consume`, `__wlo_frames`, and `__wlo_report`.
- `compiler/lower.lua`: `lower_with` lowers `with` to a `Try` whose finally
  runs the exit.
- `agents/prototypes/async/runtime/proto.lua` and `scenarios.lua`: the model
  and the scenarios reused as tests.

## Decisions

- Helpers, all called with the generated code's sites:
  - `aio_task_group()`, `aio_group_enter(g)`, and
    `aio_group_exit(g, code, value)`. The exit takes `__wlo_try`'s departure and
    returns the one to continue with: the group's failure, `"cancel"` for an
    outer request, nothing for its own absorbed stop, or the body's departure.
  - `aio_group_start(g, c)` checks admission before calling `__wlo_consume`.
  - `aio_group_cancel(g)`, `aio_task_result(t)`, and `aio_await_task(t)`.
  - `aio_scope()` and `aio_set_scope(s)` for protection, and
    `aio_sleep(seconds)`.
- A group's `cancelled` flag means it is stopping, for its own stop or for a
  failure, and stays set until it exits. Requests reach a task through its
  `scope` and the chain of `parent` groups. A group entered while protected has
  no parent, so outer requests do not reach its children.
- Protection in async functions: save the scope before `__wlo_try`, set it to
  nil around a `finally` (which covers resource exits), and restore it after.
  A `finally` that raises skips its restore, so a `Try` with handlers also
  restores right after `__wlo_try`, and a group exit restores its parent scope.
- Checkpoints: `aio_sleep` and `aio_await_task` check before they act and after
  every wake; `aio_wait_fd` checks after every wake, and async TCP operations
  check before they act. A request ends interruptible waits, which are sleeps,
  descriptor waits, and task awaits, in the order they began, so cleanup order
  is repeatable. A join is not interruptible.
- A child's failure is recorded when the child finishes. The first failure,
  from the body or a child, is the group's failure and requests its stop.
  After joining, a failure beats an outer request, which beats absorbing the
  group's own stop.
- Task tracebacks: core's `__wlo_frames` records `__wlo_task_location`, which
  the loop sets before resuming a task, and `__wlo_report` ends with
  `in task started at`. A re-raise keeps the original table, so it keeps the
  original line.
- `aio_sleep` does not validate its argument. lang's coroutine wrapper for
  `aio.sleep` does that when the coroutine runs, as `time.sleep` does.

## Test plan

`tests/unit/aio_test.lua`, through helpers shaped like the generated
`async with` and protected `finally`:

- the loop tests from plan 011, rewritten to use groups, and a request ending
  a descriptor wait;
- group states and messages, and a rejected `start` that does not consume its
  coroutine;
- `result` and task awaits: the value, an unchanged failure,
  `task is not finished`, and `task was cancelled`;
- a join that waits for children started during it;
- the first failure stopping the group, over a later failure from cleanup;
- an await of a finished task being a checkpoint;
- an admitted task entering its body under a pending request;
- a stop during a join keeping a pending return;
- the prototype scenarios: an inner group not absorbing an outer request, a
  request during cleanup of a return, a group inside protected cleanup, and an
  inner failure taking precedence over an outer request;
- the `in task started at` line.

`make test` passes.

## Implementation plan

1. Extend `runtime/aio.lua`, and record task locations in `runtime/core.lua`.
2. Rewrite and extend the unit tests.
