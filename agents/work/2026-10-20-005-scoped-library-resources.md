# Scoped library resources

## Plan

`agents/plans/2026-10-20-005-scoped-library-resources.md`

## Summary

`io.File`, `net.Connection`, and `net.Listener` are context managers whose
`enter` rejects closed, unusable, and standard handles before the body runs,
and whose `exit` closes. A generator suspended inside `with` closes its file
when closed through an outer `with`. The copy, trash, jobs, and kv examples use
`with` for their cleanup, with `enter` and `exit` on `framing.Channel` and the
kv tests' `Server`. The plan's goal is met, and the context managers milestone
is complete.

## Checks run

- `make test`: 333 passed, 0 failed.
- `./willow test examples/stdlib/kv`: 3 passed, 0 failed.

## Manual verification

1. `copy.wlo` copies a file and reports a missing source with status 1.
2. `jobs.wlo logs "echo hi" "exit 3"` reports both jobs, exits 1, and writes
   the log.
3. `trash.wlo a.txt b.txt` moves both files and appends two log lines, and
   `trash.wlo --empty .` reports `deleted 2 files`.
4. `server.wlo` with `client.wlo` answers `set`, `get`, `keys`, and `shutdown`,
   and the server process exits after `shutdown`.
