# Task group lowering and protected cleanup

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-017-task-group-lowering.md`:
`lower_group`, the `protect` marks on `try` and `with` Trys, and the
`aio_scope` and `aio_set_scope` bundling in `compiler/lower.lua`; the Try
exit, `TryCode`, and the save, clear, and restore of the task's scope in
`compiler/emit.lua`; the `aio.task_group` helper in `compiler/stdlib.lua`; the
new program tests, the async test suite, and its CLI test. The review read
them against spec §15, the `aio` part of §14, and §10's scoped cleanup and
fatal failures, and traced the group and scope helpers in `runtime/aio.lua`
that the generated code calls. Because this is the first slice in which task
groups run as Willow programs, the review exercised §15 end to end with
scratch programs and read the emitted Lua for each lowering shape.

Gaps:

- Timing-sensitive expectations in `task_groups.wlo` (the ready-order line
  depends on 10 ms timer gaps) were run 100 times under CPU load without a
  failure, but not under every scheduler condition.

## Summary

| ID | Severity | Category   | Fix  | Title                                                           |
| -- | -------- | ---------- | ---- | --------------------------------------------------------------- |
| F1 | Low      | Testing    | Fixed | No test covers the scope restore after a `finally` that raises  |
| F2 | Low      | Simplicity | Fixed | Protecting `with` exits emits scope changes nothing can observe |

## F1. No test covers the scope restore after a `finally` that raises

Low · Testing · Fixed · `compiler/emit.lua:403`

A protected `finally` or resource exit that raises skips its own restore and
leaves the task's scope nil. In a Try with handlers, emission restores the
saved scope right after the body, so code after a caught cleanup exception is
again reachable by cancellation. Without that restore, the rest of the task
runs as if it were inside protected cleanup: a later `await` ignores its
group's stop or failure, and the group's join waits for that task until its
operation finishes on its own, or forever. No test exercises this path, so
removing the restore goes unnoticed.

### Evidence

With the `if s.protect and #s.handlers > 0` restore deleted in a scratch edit
(since reverted), the unit tests and every `task_group*`, `aio*`, and
`coroutine*` program test passed (283 passed, 0 failed). A scratch program
whose child catches `ValueError` from an inner `finally`, then awaits
`aio.sleep(10.0)` while a sibling cancels the group at 0.01 s, finished at once
with the staged code and hung until a 5 s `timeout` killed it under the
mutation. The same held for an exception from a `with` exit and for one raised
in the `finally` of an awaited coroutine.

### Fix

`tests/programs/cancel_after_raising_finally.wlo` runs a task whose inner
`finally` raises, catches the exception, and sleeps while a sibling cancels the
group. The task is cancelled and the group stops; without the restore after
the handler `Try`'s body, the task cannot be cancelled and prints
`not reached` after its full sleep.

## F2. Protecting `with` exits emits scope changes nothing can observe

Low · Simplicity · Fixed · `compiler/lower.lua:713`

`lower_with` marks every `with` Try in an async function `protect`, so each
`with` saves the scope, clears it around the exit call, and restores it. A
resource `exit` is a synchronous method: §15 rules out async context managers,
and only async operations reached through `await` are checkpoints. Nothing
that runs inside an `exit`, including a generator's `close` or a future
`Connection.close`, can read the cleared scope, and `start` admits by the
group's own state. The protection therefore adds two helper calls and a local
to every `with` in async code with no effect on behavior. Leaving the scope
unchanged also needs no repair when an exit raises, since its exception
reaches the next Try with handlers or group exit before any checkpoint, the
same as today.

The plan's Protection decision lists `with` exits, so this needs the
operator's agreement.

### Evidence

`willow compile` of a two-item `with` around an `async with` in an async
function emits `aio_scope()`, `aio_set_scope(nil)`, and
`aio_set_scope(__wlo_scopeN)` around each `Res.exit` call. Tracing
`runtime/aio.lua`, `task.scope` is read only by `__wlo_aio_pending` (from
checkpoints in `sleep`, `wait_fd`, and task awaits, and from `request` for
waiting tasks), `group_enter`, and `aio_scope`; none is reachable from a
synchronous `exit`.

### Fix

`lower_with` no longer marks its `Try` as protected, so only `finally`
clauses save, clear, and restore the task's scope. A resource exit is
synchronous and reaches no checkpoint, so it stays protected from outer
cancellation as spec §15 requires. The comment on `__wlo_aio_scope` in
`runtime/aio.lua` says so.

## Checks run

- `make test` before the fixes: 371 passed, 0 failed; after them: 372 passed,
  0 failed.
- `willow test tests/suites/async`: matches the CLI test, including the
  traceback ending `in task started at`.
- Scratch programs, each matching §15:
  - the §15 square example prints 25 with `willow run`, and its `willow build`
    binary prints the same;
  - a child failure propagates after a sibling's cleanup; a grandchild failure
    reports `in task started at` for the start in its parent task; a body
    exception joins a child whose cleanup raises and propagates the body's
    exception;
  - `cancel()` is absorbed with awaiting `finally` cleanup in children; a stop
    during a join preserves a pending `return`, `break`, and `continue` in
    `for` and `while` loops and from a group inside a function;
  - an outer request reaches an inner group whose pending `return` becomes the
    outer request at the inner boundary, which the outer group absorbs, as the
    static rule for nested group exits describes;
  - a `finally` entered by an ordinary `return` finishes its awaits when the
    group's stop arrives during them;
  - `finally` clauses and a `try`/`except Exception` inside a `finally` await
    during cancellation without catching it; `except Exception` in a group
    body does not catch cancellation;
  - a `with` exit receives `None` when cancellation interrupts its body;
  - a `finally` and a `with` exit that raise, caught by `except`, leave the
    rest of the task cancellable, including through an awaited coroutine and
    in a group body;
  - groups entered inside protected cleanup ignore the outer request, absorb
    their own stop, and propagate their own failure;
  - nested generators, sync closures that cancel the group, nested async
    functions started in the group, and lambdas inside async functions with
    groups; async methods with groups and protected cleanup;
  - `sys.exit` and a stack overflow inside a group end the program without
    running cleanup;
  - `aio.task_group` used as a function value, and `cancel` on a group created
    in a synchronous `main`;
  - the deadlock and `task was cancelled` program tests report as expected.
- `willow compile` output read for: a group with and without `as`, with a
  manager expression that is a field; groups resuming `return`, `break`, and
  `continue`; a protected `try` with handlers and `finally`; a protected
  multi-item `with` around a group; a synchronous function in an async
  program, which emits no scope calls; and a synchronous program, which
  bundles no `aio` runtime.
- `task_groups.wlo` built and run 100 times under CPU load: no mismatch.

## Verdict

`async with` lowering, group exits, protected cleanup, and the removal of the
interim diagnostic match spec §15 and the plan; no behavior defect was found.
F1 adds the regression test for the scope restore after a raising cleanup,
and F2 drops the scope changes around `with` exits, which had no observable
effect.
