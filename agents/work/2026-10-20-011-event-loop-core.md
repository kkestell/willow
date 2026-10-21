# Event loop core

## Plan

`agents/plans/2026-10-20-011-event-loop-core.md`

## Summary

`runtime/aio.lua` adds tasks over Lua coroutines, a FIFO ready queue, a timer
heap, `poll` waits on descriptors with deadlines, and a run loop that reports
`deadlock: all tasks are waiting`. `__wlo_aio_wait_fd` has the contract of
`host.lua`'s `__wlo_wait_fd` but suspends the current task. Nothing in the
compiler calls the module yet. `aio.sleep`'s declaration and the deadlock
report in programs remain open in `agents/todo.md`.

## Checks run

- `tests/unit/aio_test.lua`: 5 passed.
- A one-off run of 5000 random timers checked that the heap pops in order.
- `make test`: 341 passed, 0 failed.
