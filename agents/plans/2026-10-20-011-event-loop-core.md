# Event loop core

## Goal

Add the scheduler that the "Task groups, the event loop, and cancellation"
slice builds on (spec §15, §10): tasks that wrap Lua coroutines, a FIFO ready
queue, a timer heap, `poll` waits on descriptors with deadlines, a run loop
that drives a root task, and the deadlock check. The module is not yet reachable
from Willow programs. Cancellation, task groups, `aio.sleep`'s declaration, and
compiler wiring follow once the coroutine slice merges.

## Related code

- `agents/prototypes/async/runtime/proto.lua`: the loop, wait ids, and task
  records this module follows, with a virtual clock and a timer list.
- `runtime/host.lua`: `__wlo_wait_fd(fd, events, deadline)` blocks in `poll`.
  Its TCP functions are taking the wait function as a parameter, so async TCP
  can pass the loop's version.
- `compiler/runtime.lua`: optional runtime files, whose helpers are the
  functions declared without `local`.
- `runtime/core.lua`: `__wlo_clock`, `__wlo_catch`, and `__wlo_report`, which
  prints a host failure without a location as `error: MESSAGE`.

## Decisions

- `runtime/aio.lua` is an optional runtime file. Its helpers are
  `__wlo_aio_run(body)`, `__wlo_aio_start(body)`, `__wlo_aio_sleep(seconds)`,
  and `__wlo_aio_wait_fd(fd, events, deadline)`. It declares its own `poll`
  binding so it does not depend on `host.lua` being loaded.
- A task records its outcome itself: its coroutine runs
  `xpcall(body, __wlo_catch)`, so frames stop at the task's root. Awaiting a
  Willow coroutine must call its body inside the task, not resume a Lua
  coroutine of its own, so the task's yields reach the loop.
- Every wait takes a fresh id from one counter, stored in the task's `wait`.
  A waker passes the id it registered with, and waking clears it, so a later
  waker for the same wait (a deadline after readiness, say) is ignored. The id
  also breaks ties between timers due at the same time, in registration order.
- Each loop iteration resumes the tasks that were ready when it began, then
  polls, with a zero timeout if more tasks are ready. Tasks that yield with
  `sleep(0)` cannot starve timers or descriptors.
- Stale entries are dropped lazily: descriptor waits when each `poll` set is
  built, and timers from the top of the heap. The heap empties only when no
  live timer remains, so an ended wait's deadline does not delay the deadlock
  check.
- The deadlock check raises the host failure
  `{ message = "deadlock: all tasks are waiting" }`, which `__wlo_run` reports
  as `error: deadlock: all tasks are waiting` with status 1, like other
  uncatchable failures. `__wlo_try` re-raises it, so no handler catches it.
- `__wlo_aio_run` returns the root's value or re-raises its exception with
  `error(err, 0)`.

## Test plan

`tests/unit/aio_test.lua` drives the loop with plain Lua functions:

- ready tasks run in FIFO order across `sleep(0)`;
- timers fire in deadline order;
- `wait_fd` on a pipe resumes after another task writes, and returns false at
  its deadline;
- a root failure is raised unchanged;
- the deadlock report, raised promptly despite a stale deadline timer.

`make test` passes.

## Implementation plan

1. Write `runtime/aio.lua` and register it in `compiler/runtime.lua`.
2. Add the unit test.
3. Split the loop item in `agents/todo.md` and tick the finished part.
