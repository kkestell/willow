# Scoped library resources

## Goal

Finish the context managers milestone (spec §8 Scoped cleanup, §14 `io` and
`net`):

- `io.File`, `net.Connection`, and `net.Listener` have `enter()`, returning the
  handle, and `exit(error)`, which behaves like `close`. `File.enter` rejects a
  closed file (`I/O operation on closed file`) and a standard stream
  (`cannot close a standard stream`). Connection and listener `enter` reject a
  closed or unusable handle with the error their other operations raise.
  Rejection happens before the body runs.
- A generator suspended inside `with` closes that context when it is closed,
  including through an outer `with`.
- `copy.wlo`, `trash.wlo`, `jobs.wlo`, and the `kv` client, server, and tests
  use `with` instead of `try`/`finally` cleanup. `framing.Channel` gets `enter`
  and `exit`, and the kv tests' `Server` gets them too, so its stop is scoped.

## Related code

- `compiler/stdlib.lua`: `native_record` method tables for `file`,
  `connection`, and `listener`; `optional_exception`.
- `runtime/io.lua`: `__wlo_file_close` (rejects standard streams, ignores a
  closed handle), `__wlo_usable`.
- `runtime/host.lua`: `__wlo_usable_socket`, `__wlo_net_connection_close`,
  `__wlo_net_listener_close`.
- `compiler/check.lua`: the `With` branch's `ManagerRef`, which has no `type`.
  `lower.lua` reads `node.object.type` to name the helper of a native method
  call, so native managers need it.
- `examples/stdlib/copy.wlo`, `trash.wlo`, `jobs.wlo`, `kv/client.wlo`,
  `kv/server.wlo`, `kv/framing.wlo`, `kv/test_kv.wlo`.

## Decisions

- Native methods `enter = { params = {}, result = <the handle type> }` and
  `exit = { params = { optional_exception }, names = { "error" }, result = None }`
  are added after each record is created, since `enter` returns the record's
  own type. Helpers: `file_enter` and `file_exit` in `runtime/io.lua`, and
  `net_connection_enter`/`exit` and `net_listener_enter`/`exit` in
  `runtime/host.lua`. Each exit calls the matching close.
- `ManagerRef` gets `type = manager` in check.
- `serve` in the kv server keeps its signature and wraps its loop in
  `with channel:`; `main` holds the listener in `with`. The kv tests' `Server`
  exits by stopping the process. Each test enters the server and its channels
  in one `with`. `jobs.wlo` scopes only `/dev/null`; job logs stay open until
  their jobs finish, as now.

## Test plan

- `tests/programs/scoped_resources.wlo` and `.out` (temporary files under
  `/tmp`, as in `streams.wlo`):
  - `with io.open(path) as f` reads a line, and the file is closed after the
    body (`readline` raises the closed-file error);
  - `with f:` on that closed file and `with io.stdout():` raise their errors
    without running the body;
  - a generator yielding lines from `with io.open(...)`, consumed through an
    outer `with` and left with `break`: the file it recorded is closed after
    the outer statement;
  - `with net.listen(...) as listener` and a nested
    `with net.connect(...) as connection`: both are closed afterwards
    (`recv` and `local_port` raise their closed errors), and entering the
    closed connection raises the same error.
- The rewritten examples: `copy.wlo` copies a file, `trash.wlo` still trashes,
  lists, and empties, `jobs.wlo` runs two commands, `client.wlo` talks to
  `server.wlo`, and `willow test examples/stdlib/kv` passes.
- `make test` passes.

## Implementation plan

1. Stdlib methods and runtime helpers; `ManagerRef.type`.
2. The program test.
3. The example rewrites, each run by hand.
4. Check off the task and the milestone in `agents/todo.md`.
