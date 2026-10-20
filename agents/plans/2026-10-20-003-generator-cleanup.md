# Generator cleanup

## Goal

Finish the generators milestone (spec §8 Generators). The previous task
already implemented `close`, `enter`, `exit`, and the `yield`-in-`finally`
error, because `Generator[T]` dispatch needed them. Probing shows the specified
behavior holds:

- `close()` on a suspended generator runs pending `finally` clauses from inner
  to outer and enters no `except` handler;
- closing an unstarted generator does not start it; closing an exhausted or
  closed generator has no effect;
- an exception raised by cleanup propagates from `close` and leaves the
  generator closed;
- `enter()` returns the generator and `exit(None)` closes it;
- a generator annotated `Iterator[T]` or `Iterable[T]` exposes no `close`.

This task adds the missing tests and the Rosetta Code "Generator/Exponential"
example. No compiler or runtime change is needed.

## Related code

- `runtime/core.lua`: `__wlo_generator_close`, `__wlo_generator_enter`, and
  `__wlo_generator_exit`, and the cancel departure in `__wlo_try`.
- `tests/programs/generators.wlo`: existing close coverage (one `finally`,
  skipped handler, unstarted generator).
- `examples/rosettacode/`: examples paired with expected `.out` files.

## Decisions

- Close behavior gets its own program test rather than growing
  `generators.wlo`, which covers generator functions.
- The Rosetta example filters cubes from squares with a `Generator[int]`, and
  closes it after taking the values, showing explicit cleanup.

## Test plan

- `tests/programs/generator_cleanup.wlo` and `.out`:
  - nested `try`/`finally` inside an `except Exception` around a `yield`:
    `close` logs `inner`, then `outer`, and never `handler`;
  - a second `close`, and `close` on an exhausted generator, add nothing to
    the log;
  - a `finally` raising `ValueError` during `close` propagates; the generator
    then raises `StopIteration`, and closing again is quiet;
  - `enter()` returns a generator that yields its first value; `exit(None)`
    runs its cleanup.
- `tests/unit/check_test.lua`: `close` on an `Iterator[int]` generator reports
  "type Iterator[int] has no method 'close'", and `next` on an `Iterable[int]`
  generator reports "type Iterable[int] has no method 'next'".
- `examples/rosettacode/generator_exponential.wlo` and `.out` print `529`
  through `1089`, checked with `tests/run.lua`.
- `make test` passes.

## Implementation plan

1. Add the program and unit tests.
2. Add the Rosetta example and its output.
3. Check off the task and the generators milestone in `agents/todo.md`.
