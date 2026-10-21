# Event loop core

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-011-event-loop-core.md`:
`runtime/aio.lua`, its registration in `compiler/runtime.lua`,
`tests/unit/aio_test.lua`, and the `agents/todo.md` split. The review read
them against spec §10 (the deadlock failure), §14 `aio` (`sleep(0)`), and §15
(ready order, `start`), the design review
`agents/reviews/2026-10-20-009-async-spec.md` (FIFO queue, timer heap, wait
ids), `agents/prototypes/async/runtime/proto.lua`, and `runtime/host.lua`'s
`__wlo_wait_fd` and TCP helpers, which `__wlo_aio_wait_fd` is meant to replace
in async code. It traced batch ordering, wait ids and stale wakes, the heap's
push and pop, lazy dropping of stale timers and descriptor waits, the poll
timeout, EINTR and other poll failures, the deadlock condition, and how task
and root failures surface through `__wlo_catch`, `__wlo_run`, and
`__wlo_report`.

Gaps:

- Nothing in the compiler calls the module yet, so the deadlock report was
  traced through `__wlo_run` and `__wlo_report` rather than run from a
  program.
- EINTR was traced, not reproduced; the path matches `__wlo_wait_fd`'s.
- Cancellation, groups, non-root task failures, and `aio.sleep`'s validation
  belong to later slices and were not reviewed.

## Summary

| ID | Severity | Category    | Fix  | Title                                                         |
| -- | -------- | ----------- | ---- | ------------------------------------------------------------- |
| F1 | Low      | Correctness | Fixed | Waits on a shared descriptor can make poll fail on every pass |

## F1. Waits on a shared descriptor can make poll fail on every pass

Low · Correctness · Fixed · `runtime/aio.lua:112`, `runtime/aio.lua:119`

`__wlo_aio_poll` passes one `pollfd` per waiting task, so several tasks waiting
on one descriptor (a reader and a writer on one connection, or several
acceptors on one listener) add one entry each. When the entries exceed the
soft `RLIMIT_NOFILE`, `poll` fails with `EINVAL` on every pass even though the
process holds fewer descriptors than the limit. A failed poll wakes every
descriptor waiter with `true` before due timers are processed, so:

- each waiter sees a spurious readiness, retries, gets `EAGAIN`, and waits
  again, and the loop spins at full CPU;
- a deadline never ends a wait, because the readiness wake always takes the
  wait id first, so `recv` or `accept` with a timeout never raises
  `TimeoutError`;
- every retry with a deadline pushes another timer.

macOS shells default to a soft limit of 256, so this takes about 130
connections that each have two tasks waiting at once.

### Evidence

A scratch script lowered the soft limit to 39 and started 40 tasks that each
looped `wait_fd(read_end, POLLIN, start + 0.05)` on one idle pipe until 1
second passed. No wait returned `false`; the tasks recorded about 3 million
spurious `true` wakes and gave up at 1 second. With the soft limit at 256, each
task's wait returned `false` at its deadline, with no spurious wakes.

### Fix

`__wlo_aio_poll` builds one `pollfd` per distinct descriptor, OR-ing the
events of its live waits, so the entries cannot exceed the open descriptors.
After `poll`, a wait wakes when its descriptor reports one of its own events or
`POLLERR`, `POLLHUP`, or `POLLNVAL`, so a writer is not woken by readability.
The failure path stays for genuine poll errors, as in `__wlo_wait_fd`. The
unit test `many_waits_on_one_fd_reach_their_deadlines` lowers the soft limit to
16 and checks that 40 waits on one idle pipe each return `false` at their
deadline; it fails without the fix.

## Checks run

- After the fix, `tests/unit/aio_test.lua`: 6 passed, 0 failed; `make test`:
  346 passed, 0 failed.
- `tests/unit/aio_test.lua`: 5 passed.
- Scratch scripts against the loaded runtime:
  - a task looping `sleep(0)` did not delay a ready pipe (resumed after one
    spin) or a 10 ms timer;
  - a wait that ended by readiness left its deadline timer stale, and a later
    `sleep(0.05)` in the same task was not woken early;
  - two tasks on one pipe, one with a 10 ms deadline and one without, returned
    `false` at 10 ms and `true` after the write;
  - 300 random timers fired in deadline order;
  - a past deadline returned `true` for a readable pipe and `false` for an
    idle one, as `__wlo_wait_fd` does;
  - a closed descriptor woke as ready through `POLLNVAL`;
  - a raw Lua error in the root came back as a table with its message.
- The `EINVAL` reproduction in F1.
- `make test`: 345 passed, 0 failed.

## Verdict

The loop matches the plan and the design review: FIFO batches with a poll
between them, so `sleep(0)` cannot starve timers or descriptors; wait ids that
make stale wakes harmless; a correct heap with registration-order ties; lazy
stale removal that keeps the deadlock check prompt; and root failures
re-raised unchanged. F1, duplicate descriptor entries pushing `poll` into a
persistent failure that spun the loop and disabled deadlines, is fixed by
sharing one entry per descriptor.
