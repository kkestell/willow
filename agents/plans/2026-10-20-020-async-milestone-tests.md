# Async milestone tests

## Goal

Finish the async milestone's tests with program tests for four §15 rules:
a failure waking a body suspended in `accept`, nested cleanup, resource handoff,
and failure precedence. Fix two spec problems: `await aio.sleep(0)` does not
type-check, because `sleep` takes a float, and the note at the top still says
async support is not implemented. kit's PR adds the echo server example and its
async test.

## Related code

- `tests/programs/task_groups.wlo`: `nested` covers an outer request reaching
  an inner group's body and child. `precedence` covers an inner failure beating
  a pending outer request, both caught and uncaught.
- `tests/programs/aio_sockets.wlo`: TCP operations without groups.
- `docs/spec.md`: the async note under the title, §14 `aio`, and §15 `await`.

## Decisions

- Extend `nested` in place: add a `finally` at each level and an await in the
  inner body's cleanup, and log the order in which cleanup runs.
- Extend `precedence` in place: after a caught failure, an `await
  aio.sleep(0.0)` in the outer body delivers the outer request, which skips the
  rest of the body. The group then absorbs its own stop.
- Put the two socket rules in a new `task_group_sockets.wlo`, since they need a
  listener and a client. Every wait that should be interrupted has a timeout,
  so a missed wake fails instead of hanging.

## Test plan

- `task_groups.wlo`: cleanup runs innermost first through the outer body's
  `finally`. A caught failure is followed by delivery at the next checkpoint
  and then absorption.
- `task_group_sockets.wlo`:
  - a child's failure wakes the body in `accept`, and the listener is closed
    afterwards;
  - a handed-off connection is closed when the group stops before the task's
    first turn, and also after it is served normally.
- `make test` passes.

## Implementation plan

1. Extend `task_groups.wlo` and add `task_group_sockets.wlo`.
2. Edit `docs/spec.md`.
3. Tick the Async TCP item in `agents/todo.md`.
