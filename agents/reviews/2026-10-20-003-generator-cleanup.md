# Generator cleanup review

## Scope and coverage

Reviewed the staged generator-cleanup change against
`agents/plans/2026-10-20-003-generator-cleanup.md` and spec §8 Generators:
`tests/programs/generator_cleanup.wlo` and `.out`, the two `Iterator`/`Iterable`
cases in `tests/unit/check_test.lua`, the Rosetta Code
`examples/rosettacode/generator_exponential.wlo` and `.out`, and the `todo.md`
update. The runtime paths these tests exercise were traced:
`__wlo_generator_close`, `__wlo_generator_enter`, `__wlo_generator_exit`,
`__wlo_yield`, and the `"cancel"` departure in `__wlo_try`. Scratch programs
confirmed that closing a generator whose `finally` closes another generator runs
both cleanups in order, and that an uncaught cleanup error reports the
generator's frame followed by the caller's.

Gaps:

- Closing a generator suspended inside `with` (each pending `exit` receiving
  `None`) is untested because the compiler does not yet support `with`; that
  belongs to the scoped-cleanup milestone.

## Summary

No findings.

## Checks run

- `luajit tests/run.lua tests/programs/generator_cleanup.wlo tests/programs/generators.wlo examples/rosettacode/generator_exponential.wlo tests/unit/check_test.lua`:
  64 passed, 0 failed.
- Scratch programs for nested close and an uncaught cleanup error: output and
  traceback matched spec §8 and §10.
- `make test` passed (330/330) before staging; nothing changed during the
  review.

## Verdict

The tests and example match spec §8 close, `enter`, and `exit` behavior and the
plan's test plan. No changes were needed.
