# `aio.sleep` and the root task in the event loop

## Goal

The compiler half of the event-loop item in the async milestone (spec §10,
§14 `aio`, §15):

- An `aio` module provides `sleep(seconds: float) -> Coroutine[None]`. The
  argument is checked as `time.sleep` checks it, raising `ValueError`
  `sleep length must be finite and nonnegative`. The check happens when the
  coroutine runs, at the await, not at the call. `await aio.sleep(0)` always
  suspends.
- Async `main` and async tests run as the root task of the event loop in
  `runtime/aio.lua`. The interim `__wlo_root` driver goes away.
- A deadlock is reported as `error: deadlock: all tasks are waiting` on
  stderr with status 1, and cannot be caught.

## Related code

- `runtime/aio.lua` (agent loop): `__wlo_aio_run(body)`, `__wlo_aio_sleep`,
  and the deadlock failure raised by `__wlo_aio_poll`.
- `runtime/core.lua`: `__wlo_coroutine`, `__wlo_consume`, `__wlo_root`,
  `__wlo_report`.
- `runtime/host.lua`: `__wlo_sleep`'s argument check.
- `compiler/stdlib.lua`: provided modules; a built-in's `helper` field.
- `compiler/lower.lua`: `M.lower`'s `helpers` set, which picks optional
  runtime files. `compiler/emit.lua`: the `root` function for `__wlo_run`.

## Decisions

- **Declaration.** `aio` is a provided module whose `sleep` lowers to the
  helper `aio_sleep_coroutine`, which lives in `runtime/aio.lua`. Using it
  bundles that file.
- **Validation at the await.** `__wlo_aio_sleep_coroutine(seconds, site)`
  returns `__wlo_coroutine(function() ... end)`, whose body checks `seconds`
  at the call's site and then calls `__wlo_aio_sleep`. The check repeats
  `host.lua`'s two-line test, because `host.lua` is optional.
- **Root task.** For async `main` or an async test the emitter passes
  `function() __wlo_runtime.aio_run(__wlo_consume(main())) end` to
  `__wlo_run`. `aio_run` keeps the body interface loop merged. `M.lower`
  marks `aio_run` as used when `main` or any test is async, so
  `runtime/aio.lua` is bundled. `__wlo_root` is removed.
- **Deadlock.** `__wlo_aio_poll` raises the host failure
  `{ message = "deadlock: all tasks are waiting", __wlo_frames = {} }` from
  the loop, outside any task. `__wlo_run` reports it as
  `error: deadlock: all tasks are waiting` with status 1. No change is needed.
  This slice cannot express a deadlock in Willow, because the root task can
  only wait on timers. A Willow test waits for task handles in the group slice.

## Test plan

- `tests/programs/aio_sleep.wlo`: sequential sleeps including `sleep(0)`, a
  lower bound on elapsed time, an invalid sleep created without error and
  failing at its await, and a second await of it raising the consumed error.
- `tests/programs/aio_sleep_invalid.wlo` and `.err`: an uncaught invalid
  sleep, located at the `aio.sleep` call, with frames through the awaits.
- `tests/unit/cli_test.lua`: `willow test` on async tests that sleep, one
  passing and one failing.
- `tests/unit/aio_test.lua`: the deadlock failure formats as
  `error: deadlock: all tasks are waiting`.
- `make test` passes.

## Implementation plan

1. Declare `aio.sleep`; add `__wlo_aio_sleep_coroutine`.
2. Emit the root through `aio_run`, mark it used, and remove `__wlo_root`.
3. Tests; tick the item in `agents/todo.md` and reword the coroutine item to
   the accepted model.
