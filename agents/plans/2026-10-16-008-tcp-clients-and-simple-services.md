# TCP clients and simple services

## Goal

Implement `docs/spec.md` §23: the `net` module with `connect` and `listen`,
native `Connection` (`recv`, `sendall`, `close`) and `Listener` (`accept`,
`local_port`, `close`) types, per-call timeouts, EOF, partial reads, and the
error rules. Deliver a sequential JSON-lines key-value client and server that
share framing code and reassemble split UTF-8, exercised through `willow test`
with a spawned server on an ephemeral port. Fold §23 into the baseline spec.

## Related code

- `compiler/bind.lua` — `provided`, native records (`file`, `process`), and
  `helper` names.
- `compiler/check.lua` — `builtins` with `names` and `defaults`.
- `runtime/host.lua` — the platform constants and `ffi` declarations, `poll`,
  `fcntl`, `__wlo_host_error`, `__wlo_check_timeout`, `__wlo_monotonic`,
  `__wlo_nonblocking`.
- `runtime/core.lua` — `SIGPIPE` is already ignored, so a write to a closed peer
  fails with `EPIPE`.

## Decisions

- **Declarations.** `M.modules.net` provides `connect` and `listen` (helpers
  `net_connect` and `net_listen`) and the native `Connection` (prefix
  `net_connection`) and `Listener` (prefix `net_listener`) with the §23
  signatures and defaults (`connect` timeout `30.0`, `listen` backlog `16`,
  method timeouts `None`).
- **Placement.** The helpers join `runtime/host.lua`, which has the platform
  declarations, `poll`, `fcntl`, errors, and the clock they need.
- **Resolution.** `getaddrinfo` with `SOCK_STREAM` and the port as the service
  string; `struct addrinfo` has `ai_canonname` before `ai_addr` on Linux and
  after it on macOS, so it is declared per platform. Failure raises `OSError`
  `cannot resolve <host>: <gai_strerror>`. A host must be nonempty printable
  ASCII without spaces (`ValueError` `invalid host '<host>'`); ports are 1–65535,
  or 0–65535 for `listen` (`invalid port <port>`).
- **Sockets.** Every socket is close-on-exec and non-blocking, and each call
  waits with `poll`, so one mechanism gives every timeout. `connect` tries each
  address in resolver order within one deadline, using `EINPROGRESS`, `poll`,
  and `SO_ERROR`; the last error raises `OSError`
  `cannot connect to <host>:<port>: <reason>`, and an expired deadline raises
  `TimeoutError` `connect timed out after <timeout> seconds`. `listen` sets
  `SO_REUSEADDR`, binds the first address that works, and listens (`OSError`
  `cannot listen on <host>:<port>: <reason>`). `local_port` reads the port from
  `getsockname`, at the same offset in IPv4 and IPv6 addresses.
- **Transfers.** `recv` returns one chunk of at most `size` bytes, empty at EOF,
  after waiting for readability; `sendall` writes until done within one
  deadline for the whole call. Timeouts raise `TimeoutError`
  (`recv timed out after ...`, `send timed out after ...`,
  `accept timed out after ...`) and leave the handle usable, except that any
  send failure, including its timeout, marks the connection unusable:
  later I/O raises `ValueError` `connection is unusable after a failed send`.
  Host errors raise `OSError` `cannot receive: <reason>` or
  `cannot send: <reason>`. `size` must be positive (`size must be positive`),
  `backlog` positive (`backlog must be positive`), and timeouts follow
  `__wlo_check_timeout`.
- **Lifetime.** Handles are `{ __wlo_record, fd, closed, broken }`; `close` is
  idempotent; I/O on a closed handle raises `ValueError`
  `I/O operation on closed connection` (or `listener`).
- **Example.** `examples/kv/` holds `framing.wlo` (a `LineReader` record that
  buffers received bytes, splits at byte 10, and decodes only complete lines, so
  a code point split across reads is reassembled; `send_json` and `read_json`
  on top), `server.wlo` (listens on `127.0.0.1` port 0, publishes the port by
  writing `<path>.tmp` and renaming it to the path given as its argument, then
  serves connections one at a time: `set`, `get`, `keys`, and `shutdown`
  requests, with an `error` reply for anything else), `client.wlo` (sends each
  argument as a request and prints the replies), and `test_kv.wlo`.
- **Integration test.** `test_kv.wlo` starts the server with
  `subprocess.spawn([WILLOW, "run", <server path>, <port file>])`, finding
  `server.wlo` in the working directory or in `examples/kv`, polls for the port
  file with `time.sleep` until a monotonic deadline, runs its exchanges, and in
  `finally` terminates and waits for the child and removes the port file.

## Test plan

- `tests/unit/check_test.lua`: `net.connect('h', 1).recv(4)` typed `bytes`;
  `l.accept(timeout=1.0)` typed `net.Connection`; `net.Connection()` rejected;
  `c.recv('x')` rejected.
- `tests/programs/sockets.wlo` and `.out`, in one process: listen on
  `127.0.0.1` port 0; connect to `local_port()`; accept; send and receive in both
  directions; a large `sendall` read back in several chunks of at most the
  requested size; `recv` timeout raises and the connection still works; accept
  timeout; EOF after the peer closes; idempotent `close` and `ValueError` on a
  closed handle; a send to a closed peer raises `OSError` and then `ValueError`;
  connecting to a closed port raises `OSError`; `::1` works when available (the
  test prints only whether it worked or raised `OSError`); invalid host, port,
  size, backlog, and timeout raise `ValueError`.
- `examples/kv/test_kv.wlo` through `willow test examples/kv` from
  `tests/unit/cli_test.lua` `kv_example`: set and get, keys, an unknown request,
  a request split mid code point across two sends, and two clients in sequence;
  the report shows every test passing and no server process survives.
- `kv_example` also runs `client.wlo` against a server started by the test and
  compares its output.

## Implementation plan

1. `compiler/bind.lua`, `compiler/check.lua`: `net` declarations.
2. `runtime/host.lua`: resolver, socket, and handle helpers.
3. Tests above.
4. `examples/kv/` files.
5. Verify on Linux in a container.
6. Fold §23 into `docs/spec.md` (§14 gains `### net`) and check off the
   milestone in `agents/todo.md`.

## Documentation updates

- `docs/spec.md`: `### net` in §14; the §23 heading keeps one sentence saying
  where its rules live; the top pointer and milestones introduction say section
  24 is the remaining one.
- `agents/todo.md`: check off §23.
