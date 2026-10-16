# Bytes and streaming I/O review

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-16-004-bytes-and-streaming-io.md`:
the `bytes` type in the lexer, parser, binder, checker, and lowering; the native
`io.File` type and `io` module; `runtime/bytes.lua`, `runtime/io.lua`, and the
`runtime/core.lua` changes to equality, `isinstance`, `len`, line reading,
`SIGPIPE`, and exit flushing; the two examples; the new tests; and the §19 fold
into `docs/spec.md`. Traced lowering of index, slice, `for`, methods, `==` with
boxed floats and bytes, and optional-runtime inclusion. Linux behavior was not
rerun here; the caller reported `make test` passing in a Debian bookworm arm64
container.

## Fixed

- **Spec says unclosed owned files are not flushed** (`docs/spec.md:1050`): The
  sentence "Owned files that were not closed are not flushed" was false. C
  `exit` flushes every open stdio stream, so a file written and never closed
  received its data both when `main` returned and after `sys.exit(0)`. Replaced
  it with the guarantee the design intends: data reaches an owned file only
  after `flush` or `close`.
- **`io.open` NUL-path error missing from the spec** (`docs/spec.md:1062`):
  `__wlo_open` raises `ValueError` `path contains a NUL character`, but the `io`
  section's `ValueError` list omitted it. Added it.
- **Misplaced `os.exit` comment** (`runtime/core.lua:497`): Inserting
  `__wlo_flush_streams` left the comment about `os.exit` skipping `finally`
  clauses above the flush helper. Moved it back above `__wlo_exit`.

## Findings

No open findings.

## Checks run

- Ran probe programs with `willow run`: `bytes | float` equality against a
  float, `io.File | None` and `io.File | str` narrowing, `dict[str, bytes]`,
  `bytes | str | None == None`, keyword arguments to `io.open`, `bytes`, and
  `File` methods, idempotent `close`, use after close, reading a directory
  (`OSError` `cannot read /tmp: Is a directory`), an invalid mode, field
  assignment on `io.File` (rejected), `flush` on read handles (succeeds on
  macOS), stdout flushed before an uncaught exception report, and an unclosed
  owned file after a normal return and after `sys.exit(0)` (data written in both
  cases).
- Reran the I/O probe after moving the `core.lua` comment. The spec edits need
  no test run.

## Verdict

The implementation matches the plan and spec. Three documentation and comment
findings were fixed, none remain open, and the work is committed.
