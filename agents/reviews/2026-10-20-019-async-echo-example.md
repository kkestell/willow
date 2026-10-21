# Async echo server example

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-019-async-echo-example.md`
(a replay of `908a77f`): `examples/stdlib/echo/server.wlo` and
`examples/stdlib/echo/test_echo.wlo`. The review read them as a program a user
learns async Willow from, against spec §14 `aio` and §15, especially task
groups, cancellation, "Async I/O boundaries" resource handoff, and graceful
shutdown. It ran the server against Python socket clients and ran the test
against scratch variants of the server.

No problem the example exposes is in the language or runtime. Graceful shutdown
works as §15 specifies: a `quit` closes the quitting connection, every
connection idle in `recv`, and the listener, and the process exits 0. A client
that disconnects mid-line has its partial data echoed and its connection
closed.

`agents/todo.md` still has the "An echo server example with graceful shutdown
and an async test that drives it" item and its parent "Async TCP" unticked. The
plan leaves the entry to the loop. This slice completes both.

## Summary

| ID | Severity | Category       | Fix  | Title                                                           |
| -- | -------- | -------------- | ---- | --------------------------------------------------------------- |
| F1 | High     | Error handling | Deferred | One client's connection reset stops the whole server            |
| F2 | Medium   | Testing        | Deferred | The test passes for a serial server and for one leaking connections at shutdown |
| F3 | Low      | Correctness    | Deferred | `quit` is recognized only as one exact `recv` chunk             |
| F4 | Low      | Testing        | Deferred | The test teaches an unneeded `sleep(0.0)` before connecting     |

## F1. One client's connection reset stops the whole server

High · Error handling · Deferred · `examples/stdlib/echo/server.wlo:9`

`echo` does not handle `OSError` from `recv` or `sendall`. A peer that resets
its connection makes `recv` raise `OSError: cannot receive: Connection reset
by peer`. Per §15, a child's final exception is the group's failure: it
cancels every other connection, `serve` propagates it, and the process exits
with status 1. Any remote client can therefore stop the server for all
clients. §15 states the rule this example should demonstrate: "a child must
handle an expected error within its own body to complete successfully."

### Evidence

With `willow run server.wlo 9431`, a Python client that sends `hello\n`,
reads the echo, and closes with `SO_LINGER` 0 (an RST) made the server print
the traceback below and exit 1. A later connection was refused.

```
examples/stdlib/echo/server.wlo:12:37: error: OSError: cannot receive: Connection reset by peer
  in echo at examples/stdlib/echo/server.wlo:12:20
  in task started at examples/stdlib/echo/server.wlo:25:19
```

### Fix

Deferred. The commit after the async milestone replaces `examples/` with one
program per language feature and removes `examples/stdlib/echo`, so this
example does not reach the final tree. The runtime behavior the finding rests
on is as spec §15 specifies.

## F2. The test passes for a serial server and for one leaking connections at shutdown

Medium · Testing · Deferred · `examples/stdlib/echo/test_echo.wlo:17`

The test never needs two connections to be served at the same time. Each
client sends right after connecting, and the kernel queues both connections
and their data, so a server that handles one connection at a time still
answers both. The test also sends `quit` only after the clients have closed,
so it never checks that shutdown closes a connection idle in `recv`, the main
property of the example's graceful shutdown.

### Evidence

Two scratch variants of `server.wlo` passed the staged test:

- `await echo(await listener.accept(), group)` in place of `group.start(...)`,
  a serial server.
- `echo` without `with connection:` that calls `connection.close()` only on its
  own returns, which leaves cancelled connections open.

### Fix

Deferred. The commit after the async milestone replaces `examples/` with one
program per language feature and removes `examples/stdlib/echo`, so this
example does not reach the final tree. The runtime behavior the finding rests
on is as spec §15 specifies.

## F3. `quit` is recognized only as one exact `recv` chunk

Low · Correctness · Deferred · `examples/stdlib/echo/server.wlo:15`

The header says a client that "sends the line `quit`" stops the server, but
`echo` compares each `recv` result with `quit\n`. `recv` returns whatever bytes
have arrived, so the line is missed when it is split across reads, arrives in
the same read as earlier data, or ends with `\r\n` as telnet sends it. The
example then teaches that one `recv` is one line.

### Evidence

Against `willow run server.wlo`, `quit\n` stopped the server. `quit\r\n`,
`hello\nquit\n` in one write, and `qu` then `it\n` were echoed, and the server
kept running.

### Fix

Deferred. The commit after the async milestone replaces `examples/` with one
program per language feature and removes `examples/stdlib/echo`, so this
example does not reach the final tree. The runtime behavior the finding rests
on is as spec §15 specifies.

## F4. The test teaches an unneeded `sleep(0.0)` before connecting

Low · Testing · Deferred · `examples/stdlib/echo/test_echo.wlo:16`

`await aio.sleep(0.0)  # let the server reach its first accept` suggests
that a client must wait for the server task to reach `accept`. The listener
already exists, and connections queue in its backlog until `accept` runs.

### Evidence

With the line removed, the test passed on three runs.

### Fix

Deferred. The commit after the async milestone replaces `examples/` with one
program per language feature and removes `examples/stdlib/echo`, so this
example does not reach the final tree. The runtime behavior the finding rests
on is as spec §15 specifies.

## Checks run

- `willow test examples/stdlib/echo`: 1 passed, 0 failed, on six runs.
- `willow run server.wlo <port>` with Python clients: echo, a partial line
  followed by close, `quit` closing the quitter, two connections idle in
  `recv`, and the listener (exit 0), the `quit` variants in F3, and the reset
  in F1.
- The staged test and the F2 test against scratch copies of the server:
  staged, serial, leaking, and with the F1 fix.
- `git diff --cached --check`: clean. The four staged files match `908a77f`.

## Verdict

The server follows §15's handoff rule, and its graceful shutdown closes every
connection, so the async runtime behaves as specified. As a teaching example,
it lets any client's reset stop the server (F1), and its test checks neither
the concurrency nor the shutdown it demonstrates (F2). All four findings are
deferred because a later commit removes the example.
