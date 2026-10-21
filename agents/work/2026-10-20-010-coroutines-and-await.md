# Coroutines and `await`

## Plan

`agents/plans/2026-10-20-010-coroutines-and-await.md`

## Summary

`async def` works for file-level, nested, method, and protocol declarations,
with `Coroutine[T]` annotations, `await` at level 8, and the async-only,
no-`yield`, and discard rules. A coroutine holds its body as a closure, and
`await` consumes it and runs it inline. A second consumption raises
`coroutine was already awaited or started`. Async `main` and async tests run
in a root Lua coroutine. The plan's goal is met.

## Checks run

- `make test`: 340 passed, 0 failed.

## Manual verification

1. The largest example still has room for main-chunk locals after the four
   new core helpers: `examples/stdlib/report.wlo` compiled and loaded with 50
   extra `local` lines.

## Follow-up work

- The todo says "each coroutine a Lua coroutine". The slice follows the
  review instead: each task is a Lua coroutine, and a coroutine is a body
  closure run inline by `await`.
- `async with` reports `expected 'def', found 'with'` until the task group
  slice parses it.
- `docs/spec.md` still says async support is not yet implemented.
