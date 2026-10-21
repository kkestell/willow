# Async milestone tests

## Plan

`agents/plans/2026-10-20-020-async-milestone-tests.md`

## Summary

The four §15 rules have program tests, and they found no bugs. The spec uses
`await aio.sleep(0.0)`, and the note calling async support unimplemented is
gone. The Async TCP item is ticked. kit's PR adds the echo server example
and its async test.

## Checks run

- `task_group_sockets.wlo` reports a `TimeoutError` when `serve` awaits before
  entering `with connection:`, so the handoff test catches the leak.
- `make test`: 373 passed, 0 failed.
