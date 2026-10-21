# Async milestone tests

## Plan

`agents/plans/2026-10-20-020-async-milestone-tests.md`

## Summary

The four §15 rules have program tests, and they found no bugs. The spec uses
`await aio.sleep(0.0)`, and the note calling async support unimplemented is
gone. The tests sub-item of Async TCP is ticked; the echo server example
and its async test, and with them the Async TCP item, land in the example's
commit.

## Checks run

- `task_group_sockets.wlo` reports a `TimeoutError` when `serve` awaits before
  entering `with connection:`, so the handoff test catches the leak.
- `make test`: 380 passed, 0 failed.
