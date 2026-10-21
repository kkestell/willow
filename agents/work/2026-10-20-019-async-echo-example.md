# Async echo server example

## Plan

`agents/plans/2026-10-20-019-async-echo-example.md`

## Summary

`examples/stdlib/echo/server.wlo` is an echo server: `serve(listener)` accepts
connections in a loop and starts `echo(connection, group)` for each one in an
`aio` task group. Each connection task enters `with connection:` before its
first await, so the scope is established when the task is admitted. A
connection that receives `quit\n` calls `group.cancel()` and returns; the group
interrupts the pending `accept`, joins its children, and each connection closes
through its own cleanup. `main` takes the port from `sys.args()` and runs
`serve` under `with aio.listen(...)`.

`examples/stdlib/echo/test_echo.wlo` drives the server in-process: it starts
`serve` in a group, runs two clients concurrently in a nested group, asserts
both echoes, sends `quit` on a third connection and checks the server closed
it, and asserts the server's handle finished with `None`.

## Checks run

- `willow test examples/stdlib/echo`: 1 passed, 0 failed (repeated five times).
- `willow run server.wlo 9411` with a TCP client: the echo comes back, `quit`
  closes the connection, and the process exits and releases the port.
- `make test`: 372 passed, 0 failed.
