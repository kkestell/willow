# Task groups and cancellation runtime

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-016-task-groups-runtime.md`:
the group, task handle, and cancellation helpers in `runtime/aio.lua`
(`__wlo_aio_wait`, `__wlo_aio_pending`, `__wlo_aio_checkpoint`,
`__wlo_aio_request`, `__wlo_aio_finish`, `__wlo_aio_spawn`, the group and task
helpers, the checkpoints in `__wlo_aio_sleep` and `__wlo_aio_wait_fd`, and the
loop's task location), the task location in `__wlo_frames` and `__wlo_report`
in `runtime/core.lua`, and the rewritten `tests/unit/aio_test.lua`. The review
read them against spec §15 "Task groups", "Cancellation and cleanup", and
"Competing failures", the `aio` part of §14, and §10's failures that are not
exceptions, and compared them with `agents/prototypes/async/runtime/proto.lua`
and `scenarios.lua`.

Gaps:

- No generated code calls the helpers yet, so the review drove them from Lua
  through the test file's `async_with` and `try_finally` helpers, which model
  the lowering the next slice adds. The restore after `__wlo_try` in a `Try`
  with handlers is compiler work and was not reviewed.
- `many_waits_on_one_fd_reach_their_deadlines` belongs to an earlier slice and
  was only run.

## Summary

| ID | Severity | Category    | Fix  | Title                                                             |
| -- | -------- | ----------- | ---- | ----------------------------------------------------------------- |
| F1 | Medium   | Correctness | Fixed | A fatal failure in a child task becomes a group failure           |
| F2 | Low      | Tests       | Fixed | No test covers admission while an outer request is pending        |

## F1. A fatal failure in a child task becomes a group failure

Medium · Correctness · Fixed · `runtime/aio.lua:229`, `runtime/aio.lua:197`

§15 says the fatal failures of §10 keep their immediate process-ending
behavior. `__wlo_try` re-raises a failure without `__wlo_class`, so in the
root task a stack overflow or a failed `print` ends the program at once. A
child task's coroutine instead catches every failure with
`xpcall(body, __wlo_catch)`, and `__wlo_aio_finish` records it as the group's
failure and requests the group's stop. Every sibling and the group body then
unwind and run their `finally` clauses and resource exits, which may await and
write output, before the failure reaches the root. Cleanup that never
finishes keeps the program from ending at all. The same path applies to a
failed write to stdout or stderr and a failed read of stdin
(`__wlo_host_fail`).

### Evidence

A scratch script driving the runtime as the unit tests do:

```lua
local function recurse(n) return 1 + recurse(n + 1) end
run(function()
  local g = A.task_group()
  async_with(g, function()
    start(g, function()
      try_finally(function() A.sleep(10) end, function()
        log[#log + 1] = "sibling cleanup ran"
        A.sleep(0.05)
        log[#log + 1] = "sibling cleanup awaited"
      end)
    end)
    start(g, function() A.sleep(0); recurse(1) end)
    A.sleep(10)
  end)
end)
```

`run` raised `stack overflow` only after the log read
`sibling cleanup ran; sibling cleanup awaited`. A raw Lua error in the child
(indexing `nil`) behaved the same way and also ran the body's cleanup.

### Fix

`__wlo_aio_spawn` re-raises a failure that is neither `__wlo_cancel` nor an
exception, as `__wlo_try` does, so it leaves `coroutine.resume` instead of
reaching `__wlo_aio_finish`. `__wlo_aio_run` clears the current task and task
location and raises it unchanged. The unit test
`fatal_failure_in_a_task_skips_group_cleanup` starts a sibling with cleanup and
a child that raises a non-exception failure, and checks that `run` raises it
without running the cleanup; it fails without the fix.

## F2. No test covers admission while an outer request is pending

Low · Tests · Fixed · `tests/unit/aio_test.lua:368`, `runtime/aio.lua:285`

§15 makes admission depend only on the group's own state: an inner group
still accepts tasks while an outer group's request is pending, and the
admitted task receives the request at its first checkpoint. The prototype's
`group_start` checks the whole request chain and rejects the start, which is
the plausible regression. `admitted_task_enters_its_body_before_a_checkpoint`
covers only the group's own stop, and the scenario tests start their inner
tasks before the outer request.

### Evidence

In a scratch copy of the repository, changing the check in
`__wlo_aio_group_start` to `__wlo_aio_pending({ scope = group })`, the
prototype's rule, left all 18 tests in `tests/unit/aio_test.lua` passing. A
scratch scenario showed the difference: with the staged code, a start into an
inner group entered after `cancel` on the outer group succeeded, the child
logged its entry and was cancelled at its first `sleep`, and the outer group
absorbed its stop; under the mutation the start raised
`task group is not accepting tasks`.

### Fix

The unit test `inner_group_admits_tasks_under_an_outer_request` cancels the
outer group, enters an inner group, and starts a child, which enters its body,
is cancelled at its first checkpoint, and lets the outer group absorb its own
stop.

## Checks run

- After the fixes, `tests/unit/aio_test.lua`: 20 passed, 0 failed; `make test`:
  366 passed, 0 failed.

- `tests/unit/aio_test.lua`: 18 passed. `make test`: 364 passed, 0 failed.
- Scratch scenarios through the test file's helpers, each matching §15:
  - a start during a stopping join raises `task group is not accepting tasks`,
    and `cancel` during the join is idempotent;
  - a child failure from cleanup after the group's own stop propagates instead
    of being absorbed;
  - an exception reaching the requesting group's boundary propagates from it;
  - a request wakes tasks in a sleep and in a task await, and cleanup runs in
    the order the waits began;
  - a child's protected cleanup sleeps its full time after its group stops;
  - an awaited child's failure stops the body at that await's checkpoint;
  - a stop during a join keeps a pending `break`;
  - an outer request during an inner join with a pending return is delivered
    at the inner boundary after the inner child's cleanup;
  - a failure from the body's protected cleanup becomes the group's failure;
  - a group exit restores the parent scope after a `finally` raised past its
    restore.
- `assert(coroutine.resume(co))` in LuaJIT re-raises a table error unchanged,
  which the F1 fix relies on.

## Verdict

Group states and messages, admission, joining, first-failure recording,
protection, persistent requests, failure precedence, preserved departures,
task handles, and task tracebacks match spec §15. F1, a fatal failure in a
child task running other tasks' cleanup before the program ended, is fixed so
the failure leaves the loop at once; F2 adds the regression test for the
admission rule the prototype got wrong.
