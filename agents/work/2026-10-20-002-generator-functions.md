# Generator functions

## Plan

`agents/plans/2026-10-20-002-generator-functions.md`

## Summary

`yield` statements make generator functions, annotated `Generator[T]`,
`Iterator[T]`, or `Iterable[T]`, whose bodies run in coroutines from the first
`next`. Exhaustion, body exceptions, `generator raised StopIteration`, and
`generator already running` behave as specified. Generators work with `for`,
`iter`, and `next`, and a `yield` forgets captured narrowing. A private cancel
value lets `close` run pending `finally` clauses without entering `except`
handlers. The plan's goal is met.

## Checks run

- `make test`: 329 passed, 0 failed.

## Manual verification

1. A captured variable narrowed inside a nested generator stays narrowed when
   no `yield` comes between the test and its use.

   ```sh
   # x = m() (int | None); def g() -> Iterator[int]: if x is not None: yield x + 1
   ./willow run n.wlo
   ```

   Printed `2`.

2. The main chunk's local headroom after the runtime additions.

   ```sh
   ./willow compile examples/stdlib/report.wlo -o r.lua
   # append N `local` lines and load with LuaJIT
   ```

   It loads with 50 extra locals and fails at 60.

## Follow-up work

- Each iteration and generator task added core runtime locals, leaving about
  50 of Lua's 200 main-chunk locals in the largest example. Later runtime
  additions may need to share a table, or move into an optional runtime file
  like `runtime/io.lua`.
