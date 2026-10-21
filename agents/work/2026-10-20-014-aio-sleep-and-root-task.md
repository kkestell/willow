# `aio.sleep` and the root task in the event loop

## Plan

`agents/plans/2026-10-20-014-aio-sleep-and-root-task.md`

## Summary

`aio.sleep` returns a coroutine that checks its argument when awaited and
suspends through the event loop. Async `main` and async tests run as the
loop's root task, so programs that use them bundle `runtime/aio.lua`, and
`__wlo_root` is gone. The deadlock failure formats as specified. The plan's
goal is met.

## Checks run

- `make test`: 349 passed, 0 failed.

## Follow-up work

- No Willow program can deadlock until task handles exist. The group slice
  should add `deadlock.wlo` from `agents/prototypes/async/programs/` as a
  program test.
