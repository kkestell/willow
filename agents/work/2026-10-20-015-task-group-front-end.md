# Task group front end and static checking

## Plan

`agents/plans/2026-10-20-015-task-group-front-end.md`

## Summary

`aio.task_group`, `aio.TaskGroup`, `aio.Task[T]`, task awaits, and
`async with` are declared, parsed, and checked. The §15 rule treats awaits and
nested group exits as transfers to the ends of enclosing groups, through
`finally` and `with` cleanup. Lowering reports
`task groups are not implemented yet` until the group runtime merges. The
plan's goal is met.

## Checks run

- `make test`: 350 passed, 0 failed.

## Follow-up work

- Lower `async with` and protect `finally` in async functions with loop's
  `aio_scope` and `aio_set_scope`, then replace
  `tests/programs/task_group_unimplemented.wlo` with group programs and
  `deadlock.wlo`.
- `willow check` does not lower, so it accepts programs that use groups.
