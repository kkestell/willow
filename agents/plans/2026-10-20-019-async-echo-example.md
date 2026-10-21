# Async echo server example

## Goal

Add `examples/stdlib/echo/`: a runnable echo server that accepts connections in
a loop, starts one task per connection in a task group, and stops when a client
sends the line `quit`; and an async test that drives it in-process.

## Related code

- `examples/stdlib/kv/`: the layout for a runnable server with its own test
  (`server.wlo`, `test_kv.wlo`), run with `willow test examples/stdlib/kv`.
- `docs/spec.md` §14 `aio`: the echo example, `listen`, `accept`, `recv`,
  `sendall`, and `task_group`. §15 "Async I/O boundaries": a caller scopes or
  hands off an acquired connection before its next await.
- `tests/programs/aio_sockets.wlo`: the async TCP program test, which uses the
  same `with await aio.connect(...) as` and `group.start(...)` shapes.

## Decisions

- `examples/stdlib/echo/server.wlo` holds `serve(listener)` (the accepting loop
  and its group), `echo(connection, group)` (one connection per task), and an
  async `main` taking the port from `sys.args()`.
- `serve` starts `echo(await listener.accept(), group)`, so the connection is
  handed to the task whose first statement is `with connection:`. That task
  establishes the scope before its first await, as §15 requires.
- A connection that receives `quit\n` calls `group.cancel()` and returns. The
  request interrupts the accepting loop at its pending `accept`, the group
  joins its children, and every connection is closed by its own `with` cleanup
  before `serve` returns normally.
- `test_echo.wlo` starts `serve` in a group, asks two clients concurrently
  through a nested group and reads their handles after it, sends `quit`, checks
  that the server closed the connection, and checks the server's task handle
  finished with `None`.

## Test plan

- `willow test examples/stdlib/echo`: 1 passed, 0 failed.
- Run `server.wlo` and talk to it over TCP: an echo, then `quit` closing the
  connection and exiting the process.
- `make test`.
- loop owns the `agents/todo.md` entry for this slice.

## Implementation plan

1. Add `server.wlo` and `test_echo.wlo`.
2. Run the example's test, the manual server check, and `make test`.
