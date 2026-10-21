# `aio.sleep` and the root task in the event loop

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-014-aio-sleep-and-root-task.md`,
a replay of `aa061db`: the `aio` module and its `sleep` declaration in
`compiler/stdlib.lua`, the `aio_run` helper marking in `M.lower`
(`compiler/lower.lua`), the `root` function in `compiler/emit.lua`,
`__wlo_aio_sleep_coroutine` in `runtime/aio.lua`, the removal of `__wlo_root`
from `runtime/core.lua`, the new program and unit tests, `agents/todo.md`, and
the work log. The review read them against spec §1 (async `main`, exit
statuses), §10 (the deadlock failure), §12 (async tests), §14 `aio` and `time`
(`sleep` validation, `sleep(0)`), and §15. It traced how a root task's failure
leaves `__wlo_aio_run` and reaches `__wlo_run` and `__wlo_report`, how
`runtime/aio.lua` is bundled through `compiler/runtime.lua`, and the test
chunk that `willow test` runs. The scheduler from the previous slice, including
the one-pollfd-per-descriptor fix applied during this replay, was read as
context.

Gaps:

- No Willow program can deadlock yet, because the root task can only wait on
  timers. The deadlock report was checked through the unit test and by tracing
  `__wlo_aio_poll` to `__wlo_run`, not from a program.
- `sleep(0)` ordering against other ready tasks needs task groups, which a
  later slice adds. It was traced through `__wlo_aio_sleep` and
  `__wlo_aio_poll`, and the previous slice's unit tests cover it.

## Summary

| ID | Severity | Category      | Fix  | Title                                      |
| -- | -------- | ------------- | ---- | ------------------------------------------ |
| F1 | Low      | Documentation | Fixed | The work log records a stale test count    |

## F1. The work log records a stale test count

Low · Documentation · Fixed · `agents/work/2026-10-20-014-aio-sleep-and-root-task.md:17`

The work log's checks section says `make test: 348 passed, 0 failed`. The
staged slice gives 349. The replay base gained a test from the
one-pollfd-per-descriptor fix in the previous slice, so the count carried over
from `aa061db` no longer matches the staged tree.

### Evidence

`make test` on the staged tree printed `349 passed, 0 failed`. An export of
`HEAD` (`git archive HEAD`) printed `346 passed, 0 failed`, and the slice adds
three tests: `aio_sleep.wlo`, `aio_sleep_invalid.wlo`, and
`async_tests_run_in_the_event_loop`.

### Fix

The work log records `make test: 349 passed, 0 failed.`

## Checks run

- `make test`: 349 passed, 0 failed.
- Scratch programs under `willow run`:
  - `aio.sleep` with NaN and infinity raised `ValueError`
    `sleep length must be finite and nonnegative` at the await; `-0.0` and
    `0.0` slept.
  - A sync `main` that creates an `aio.sleep` coroutine without awaiting it
    printed its output and exited 0.
  - A plain async `main` with no awaits printed its output and exited 0.
  - 1000 `await aio.sleep(0.0)` calls in a row finished well under a second.
  - An exception raised after a sleep in a nested coroutine reported the raise
    location and the frames through `main`, with status 1.
  - `sys.exit(3)` after a sleep inside `try`/`finally` exited 3 without
    running the `finally` clause.
  - Unbounded recursion after a sleep reported `stack overflow` with frames
    and status 1, as a sync `main` does.
  - `aio.sleep` as a function value with an expected callable type
    validated at the await; without one it reported
    `function 'aio.sleep' needs an expected callable type`.
- `willow compile` and `willow build` of async programs: the output bundles
  `runtime/aio.lua`, ends with
  `__wlo_run(function() __wlo_runtime.aio_run(__wlo_consume(main())) end, ...)`,
  and runs with the same output, traceback, and status as `willow run`.
- `willow test` on a file with sync and async tests: the async passing test
  passed; the async test raising after a sleep failed with its frames and
  status 1; the async test calling `sys.exit(0)` failed with exit status 0;
  `--check` passed.
- `git diff --cached --check`: clean. No `__wlo_root` references remain.

## Verdict

The slice meets its plan. `aio.sleep` validates at the await as `time.sleep`
does, async `main` and async tests run as the event loop's root task in run,
compile, build, and test, failures and `sys.exit` keep their statuses and
tracebacks, and the deadlock failure formats as §10 requires and is raised
outside any task, so no handler can catch it. The one finding is a stale test
count in the work log.
