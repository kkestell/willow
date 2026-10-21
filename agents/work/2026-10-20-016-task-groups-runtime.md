# Task groups and cancellation runtime

## Plan

`agents/plans/2026-10-20-016-task-groups-runtime.md`

## Summary

`runtime/aio.lua` implements task groups, task handles, and cancellation, as
the plan describes. `__wlo_report` ends a task's traceback with
`in task started at`. No generated code calls the helpers yet: the front end and
lowering of `async with` and the `aio` declarations are in progress, so the
todo items stay open until programs can use them.

## Checks run

- `tests/unit/aio_test.lua`: 17 passed. Each test failed under a mutation of
  the rule it covers: failure precedence, protection, the await checkpoint,
  task locations, outer requests at an inner boundary, admitted tasks entering
  their bodies, and join wakeups.
- `make test`: 357 passed, 0 failed.
