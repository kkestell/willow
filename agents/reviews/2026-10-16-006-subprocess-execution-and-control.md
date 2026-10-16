# Subprocess execution and control review

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-16-005-subprocess-execution-and-control.md`: the
`subprocess` declarations in `compiler/bind.lua`, the `run`/`spawn` signatures
and method defaults in `compiler/check.lua`, the `helper` lowering in
`compiler/lower.lua`, read tracking in `runtime/core.lua` and `runtime/io.lua`,
the process helpers in `runtime/host.lua`, `examples/wrap.wlo`, the new tests,
and the §20 fold into `docs/spec.md` and `agents/todo.md`. Traced the `run`
poll loop (input, capture, timeout, and exit paths), descriptor ownership and
close-on-exec, redirect setup, status decoding and caching, the buffered-stdin
check, and FFI declaration sizes on macOS and glibc. Linux x64 was not rerun
after the review fix; Linux arm64 was.

## Fixed

- **Swapped child stdout and stderr both reach one stream**
  (`runtime/host.lua:487`): `spawn(..., stdout=io.stderr(), stderr=io.stdout())`
  added `dup2(2, 1)` then `dup2(1, 2)`, so the second action copied the
  already-replaced descriptor 1 and both of the child's streams went to the
  parent's stderr. `__wlo_launch` now copies a redirect source among 0, 1, and
  2 to a close-on-exec descriptor of 3 or above before adding its `dup2`, and
  closes the copies after `posix_spawn`. Added a regression case to
  `tests/programs/processes.wlo`.
- **Flush failure rule dropped from the spec** (`docs/spec.md:1166`): The folded
  §14 text said the streams are flushed before a child starts but no longer said
  that a failed flush raises `OSError` and prevents the launch, which the
  accepted §20 text required and the implementation does. Restored the
  sentence.

## Findings

No open findings.

## Checks run

- Probe programs with `willow run`: swapped stdout/stderr (both went to stderr
  before the fix, correct after); 300 000 bytes on each of stdout and stderr
  captured together (no deadlock); `sh -c 'sleep 3 & echo hi'` with capture
  returning in under a second; `input` with a timeout and inherited output;
  a missing `cwd` (`OSError` `cannot run sh: No such file or directory`); a
  seekable `stdin` rejected after `readline` and accepted after reading to end
  of file; a flush failure with stdout closed (`OSError`
  `cannot write <stdout>: Bad file descriptor`, child not started).
- `make test` on macOS arm64: 237 passed, 0 failed.
- `processes.wlo`, `processes_stdin.wlo`, and `tests/unit/cli_test.lua` in a
  `gcc:13-bookworm` arm64 container: 30 passed, 0 failed.

## Verdict

The subprocess milestone matches the plan and spec. Two findings were fixed and
none remain open, so the staged work is ready to commit.
