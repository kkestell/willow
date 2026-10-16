# TCP clients and simple services

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-16-008-tcp-clients-and-simple-services.md`: the `net`
declarations in `compiler/bind.lua` and `compiler/check.lua`, the socket helpers
in `runtime/host.lua`, `docs/spec.md` §14 `net` and the §23 fold, the
`examples/kv/` client, server, framing module, and tests, `tests/programs/sockets.wlo`,
and the new unit tests. Platform constants and the `addrinfo` layouts were checked
against the macOS and Linux headers' published values. Linux behavior relies on
the reported container run; this review ran checks on macOS arm64 only.

## Fixed

- **A `null` request closes the connection without a reply**
  (`examples/kv/server.wlo:47`): `framing.read_json` returns `None` both at end of
  stream and for the JSON line `null`, so the server treated a `null` request as a
  disconnect and closed the connection instead of replying with an error. The
  server now reads a line with `framing.read_line`, treats only `None` from it as
  end of stream, and parses the line itself; `null` gets
  `{"error":"expected an object"}`.
- **Invalid UTF-8 from a client stops the server** (`examples/kv/server.wlo:51`):
  `read_line` raises `ValueError` `invalid UTF-8`, which `serve` did not catch, so
  one bad line ended the server process. `serve` now replies with an `error`
  message and continues, as it does for invalid JSON.
- **A client that disconnects early stops the server**
  (`examples/kv/server.wlo:80`): a client that closes without reading its reply
  causes a reset, so the next `recv` or `sendall` raises `OSError` and the
  sequential server exited. The accept loop now reports the failure on stderr and
  serves the next connection.
- **A server that does not start in time is left running**
  (`examples/kv/test_kv.wlo:31`): `_start` asserted on its deadline without
  stopping the spawned child, and callers' `finally` blocks do not cover `_start`,
  so a slow server outlived the test run. `_start` now terminates and waits for the
  child before raising.

## Findings

No open findings.

## Checks run

- Reproduced each server failure with small clients against
  `willow run examples/kv/server.wlo`: before the fixes, `null` returned end of
  stream, `bytes([255, 10])` killed the server with `ValueError`, and an early
  close killed it with `OSError: cannot receive: Connection reset by peer`; after
  the fixes, the server replied or logged `client failed: ...` and kept serving.
- Timed a 64 MiB `sendall` over loopback to a separate process (0.02 s), so the
  per-attempt remainder copy in `__wlo_net_connection_sendall` is not a measurable
  cost.
- `willow test examples/kv`: 3 passed.
- `make test`: 249 passed, 0 failed.

## Verdict

The `net` runtime, declarations, and spec match the plan. Four example-service and
test-cleanup defects were fixed; nothing remains open.
