# Async milestone tests

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-020-async-milestone-tests.md`,
replaying commit 902924c: the extended `nested` and `precedence` cases in
`tests/programs/task_groups.wlo`, the new `tests/programs/task_group_sockets.wlo`,
the `aio.sleep(0.0)` and async-note edits in `docs/spec.md`, and the Async TCP
items in `agents/todo.md`. The review read the tests against spec §15
"Task groups", "Cancellation and cleanup", "Competing failures", and "Async I/O
boundaries", and checked each test against scratch mutations of
`runtime/aio.lua`, `runtime/aio_net.lua`, and `compiler/emit.lua`, all reverted
afterwards. The runtime beneath the tests is as earlier slices left it,
including one pollfd per descriptor, fatal task failures ending the program,
and `__wlo_aio_fd_waits` initialized at load.

Gaps:

- Linux was not run; every check ran on macOS.
- The echo server example and its async test belong to a later commit and were
  not reviewed.

## Summary

| ID | Severity | Category      | Fix  | Title                                                                |
| -- | -------- | ------------- | ---- | -------------------------------------------------------------------- |
| F1 | Low      | Testing       | Fixed | The accept test passes when a child's failure does not wake `accept` |
| F2 | Low      | Testing       | Fixed | A listener left open by its `with` makes the test hang               |
| F3 | Low      | Documentation | Fixed | `agents/todo.md` marks the echo server example done                  |

## F1. The accept test passes when a child's failure does not wake `accept`

Low · Testing · Fixed · `tests/programs/task_group_sockets.wlo:20`

The first case is meant to show that a child's failure wakes the body
suspended in `listener.accept(timeout=5.0)`. If the failure never reaches the
accept, the accept times out after 5 seconds and raises `TimeoutError` from the
body. The group has already recorded the child's `ValueError` as its first
failure, so it still propagates `ValueError`, and the output is the same. The
test only takes 5 seconds longer. The plan's decision says each interrupted
wait has a timeout "so a missed wake fails instead of hanging", but here the
timeout leads to the same output.

Other tests catch the same runtime faults: with fd waits made non-interruptible,
`tests/unit/aio_test.lua` hangs. The new program test adds no check of this
rule.

### Evidence

Two scratch mutations of `runtime/aio.lua`, each reverted:

- `__wlo_aio_finish` records a child's failure without calling
  `__wlo_aio_request(group)`;
- `__wlo_aio_wait_fd` begins its wait with `__wlo_aio_wait(false)`, so a
  request does not wake it.

Under both, `tests/run.lua tests/programs/task_group_sockets.wlo` reported
`1 passed, 0 failed` after 5 seconds, against under 1 second unmutated.

### Fix

The accept now has a one-second timeout inside `try` with
`except TimeoutError`, which prints `accept was not woken`. Cancellation
bypasses `except`, so the line appears only when the child's failure does not
wake the accept. With `__wlo_aio_request(group)` removed from
`__wlo_aio_finish`, the test now fails.

## F2. A listener left open by its `with` makes the test hang

Low · Testing · Fixed · `tests/programs/task_group_sockets.wlo:25`

The case checks the listener's `with` cleanup by calling `await
listener.accept()` with no timeout and expecting the closed-listener
`ValueError`. If the cleanup does not run, the listener stays open and no
client connects, so the accept waits forever. `make test` then hangs instead
of reporting a failure, which contradicts the plan's aim that a missed wake
fails instead of hanging.

### Evidence

A scratch mutation of `runtime/aio_net.lua` removed the
`__wlo_aio_listener_close` call from `__wlo_aio_listener_exit`, and was
reverted afterwards. `tests/run.lua tests/programs/task_group_sockets.wlo`
was still running after two minutes and had to be killed.

### Fix

The second accept has a one-second timeout. A closed listener still raises the
closed-handle `ValueError` at once; with `__wlo_aio_listener_exit` not closing
the listener, the test now fails in about a second instead of hanging.

## F3. `agents/todo.md` marks the echo server example done

Low · Documentation · Fixed · `agents/todo.md:43`, `agents/todo.md:51`

The slice ticks the last Async TCP sub-item, "An echo server example with
graceful shutdown and an async test that drives it; tests for a failure waking
an accepting body, nested cleanup, resource handoff, and failure precedence",
and with it the parent "Async TCP" item. This slice adds only the four tests.
The example and its test arrive in a later commit, so for now the todo list
calls the milestone complete when it is not. The plan and work log both say
that kit's PR adds the example.

### Evidence

`ls examples` shows no echo server, and no test under `tests/` drives one.

### Fix

`agents/todo.md` splits the sub-item. The tests for a failure waking an
accepting body, nested cleanup, resource handoff, and failure precedence are
ticked; the echo server example and the parent Async TCP item stay unticked
until the example's commit.

## Checks run

- After the fixes, `task_group_sockets.wlo` passed three consecutive runs and
  failed under both mutations above; `make test`: 380 passed, 0 failed.

- `make`, then `vendor/luajit/src/luajit tests/run.lua
  tests/programs/task_groups.wlo tests/programs/task_group_sockets.wlo`: 2
  passed.
- `make test`: 380 passed, 0 failed.
- Determinism: both tests ran 40 times idle and 40 times with 30 `yes`
  processes loading 10 cores. All 160 runs passed. In `precedence`, the
  stopper's timer (0.02) and the cleanup's timer (at least 0.04) are popped by
  deadline even after a stall, so the outer request always arrives before the
  inner cleanup ends. The remaining timing dependency, the failing child's
  0.01 timer against the stopper's 0.02, was already in the test before this
  slice.
- Mutations the tests catch, each reverted:
  - `__wlo_aio_group_exit` delivering a pending outer request before the
    group's failure: `precedence` prints `absorbed` alone, and the uncaught
    case does not propagate.
  - A propagated inner failure clearing the outer groups' requests:
    `caught child failed, unreachable, absorbed`.
  - A requesting group absorbing its own stop even when its body raised: the
    `propagated child failed` line is missing.
  - `finally` in async code not clearing the scope (`compiler/emit.lua`): the
    `nested` line loses the inner body's and child's cleanup.
  - Children seeing only their own group's request, not an outer one:
    `nested` logs `inner child woke` after 10 seconds.
  - A task whose group was cancelled before its first turn finishing without
    entering its body: the handoff case raises `TimeoutError` from the
    client's `recv`.
- A scratch copy of `task_group_sockets.wlo` with `await aio.sleep(0.0)`
  before `with connection:` in `serve` fails with `TimeoutError: recv timed
  out after 5.0 seconds`, as the work log says.
- `grep` over `docs/`, `README.md`, and `AGENTS.md`: there is no other
  `sleep(0)` with an int argument, and nothing else calls async
  unimplemented.

## Verdict

The nested-cleanup, handoff, and precedence tests pin their rules, and their
output was stable across 160 runs, including runs under CPU load. The spec
edits are complete. The accept case now fails when a child's failure does not
wake the accept (F1) and when the listener's cleanup does not close it (F2),
and the todo list leaves the echo server example open until it exists (F3).
