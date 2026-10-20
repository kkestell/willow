# Scoped library resources

## Scope and coverage

The staged changes for
`agents/plans/2026-10-20-005-scoped-library-resources.md`: the `enter` and
`exit` native methods on `io.File`, `net.Connection`, and `net.Listener`
(`compiler/stdlib.lua`, `runtime/io.lua`, `runtime/host.lua`), the `type` on
check's `ManagerRef` and its use in `lower.lua`'s native method lowering,
`tests/programs/scoped_resources.wlo`, and the `with` rewrites of `copy.wlo`,
`trash.wlo`, `jobs.wlo`, and the `kv` client, server, framing, and tests. The
review read them against spec §3, §8 Scoped cleanup, and the §14 `io` and `net`
sections.

Gaps:

- Entering a connection made unusable by a failed send was traced through
  `__wlo_usable_socket`, not reproduced.

## Summary

No findings.

## Checks run

- `./willow run tests/programs/scoped_resources.wlo`: output matches
  `scoped_resources.out`.
- A program passing an `io.File` as `ContextManager[io.File]`, to a function
  and through a list, entered and closed the file through protocol dispatch.
- `./willow test examples/stdlib/kv`: 3 passed, 0 failed; no server process
  remained afterwards.
- `copy.wlo` copied a 200000-byte file exactly; `jobs.wlo logs "echo hi"
  "exit 3"` reported both jobs and exited 1; `trash.wlo a.txt` moved the file
  and wrote its log line.

## Verdict

The native managers meet the spec: `enter` rejects closed, unusable, and
standard handles before the body runs, `exit` closes, and the rewritten
examples keep their behavior while closing their resources on every path. The
change is ready to commit.
