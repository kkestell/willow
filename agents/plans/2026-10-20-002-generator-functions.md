# Generator functions

## Goal

First task of the generators milestone (spec §8 Generators, §9 Captures):

- `yield expression` is a statement. A function whose own body contains one is
  a generator function, annotated `Generator[T]`, `Iterator[T]`, or
  `Iterable[T]`; each yielded value must be assignable to `T`.
- Calling it binds arguments and returns a generator without running the body.
  The body starts on the first `next` and resumes after each `yield`.
- Bare `return` or the end of the body exhausts the generator; `return value`
  is an error, and there is no every-path rule. An exhausted generator raises
  `StopIteration` on every `next`. A body exception closes the generator and
  propagates. A `StopIteration` escaping the body becomes `RuntimeError`
  `generator raised StopIteration`. Resuming a running generator raises
  `RuntimeError` `generator already running`.
- Generators work with `for`, `iter`, and `next`.
- A `yield` removes the narrowing of captured bindings, like a call.
- Each generator is a coroutine. A private cancel value raised at a `yield` is
  reported by `__wlo_try` as a `"cancel"` departure: protected blocks skip
  `except` handlers, run `finally`, and raise it again, and the coroutine
  boundary catches it.

The `Generator` protocol also requires `close`, `enter`, and `exit`, and
dispatch needs an entry for each method, so the generator run-time type
provides them now: `close` cancels a suspended generator through the
mechanism above, marks an unstarted one closed without starting it, and does
nothing to a finished one. `enter` returns the generator, and `exit` closes
it. `yield` directly inside a `finally` clause is rejected, so closing never
meets a `yield`. The next task covers close's full behavior (cleanup errors,
inner-to-outer order, annotations hiding `close`) and its tests.

## Related code

- `compiler/parser.lua`: `yield` is in `unsupported`; `raise` shows a simple
  statement with an expression.
- `compiler/bind.lua`: `resolve_function`'s statement walk and its `calls`
  count, which loops use to forget captured narrowing.
- `compiler/check.lua`: `check_function` (return type, `finally_depth`, the
  every-path rule), the `Return` statement, and `forget_captured`.
- `compiler/lower.lua`: `lower_function` and its returned record; statements.
- `compiler/emit.lua`: `function_body`, `Try` emission (`if code == "raise"`
  then `__wlo_reraise`).
- `runtime/core.lua`: `__wlo_catch`, `__wlo_try`, `__wlo_frames`, `__wlo_fail`.
- `compiler/stdlib.lua`: `dispatched` run-time types and the `Generator`
  protocol.

## Decisions

- **Syntax.** The parser removes `yield` from `unsupported` and parses
  `yield expression` as a `Yield` statement; the expression is required (use
  `yield None`).
- **Binding.** `resolve_function` marks `fn.generator` when its own body has a
  `Yield` (nested functions are walked separately) and counts the yield in
  `calls`.
- **Checking.** For a generator function:
  - the resolved return type must be `Generator[T]`, `Iterator[T]`, or
    `Iterable[T]`, or the function reports "a generator function must be
    annotated Generator[T], Iterator[T], or Iterable[T]"; its yield type is `T`;
  - `return value` reports "a generator cannot return a value"; bare `return`
    is allowed, and the every-path rule is skipped;
  - `yield` values are checked against `T`; a `yield` under `finally_depth > 0`
    reports "'yield' cannot be used in a 'finally' clause"; after a `yield`,
    captured narrowing is forgotten and the yield counts as a call.
  A `yield` in an ordinary function cannot happen, since that makes it a
  generator.
- **Lowering and emission.** A lowered generator function has `generator =
  true`; `function_body` emits `return __wlo_generator(function() ... end)`
  around its locals and body, so the parameters are bound by the outer call and
  the body runs only when resumed. `Yield` lowers to `Eval` of
  `__wlo_yield(value)`, with the value converted to `T`'s representation. Lines
  inside the closure keep the generator function's frame name.
- **Run time** (`runtime/core.lua`):
  - `__wlo_generator(body)` returns
    `{ __wlo_record = "<generator>", state = "unstarted", co = ... }`, whose
    coroutine runs `xpcall(body, __wlo_catch)`, so errors are caught where they
    happen and their frames recorded inside the coroutine.
  - `__wlo_yield(value)` yields `value` and raises `__wlo_cancel` if resumed
    with it.
  - `__wlo_generator_next` checks `running` and `done`, resumes, and returns
    the yielded value. When the coroutine finishes, normal completion raises
    `StopIteration`, `StopIteration` from the body raises the `RuntimeError`,
    and any other error is raised again with the caller's frames appended to
    the generator's, so tracebacks show both.
  - `__wlo_generator_close` resumes a suspended generator with `__wlo_cancel`
    and raises any error other than the cancel value. It leaves the generator
    `done` in every case. `iter` and `enter` return the generator, and
    `exit(error)` closes it.
  - `__wlo_try` returns `"cancel", __wlo_cancel` for the cancel value before
    its host-failure check; `Try` emission raises it again after `finally`,
    like `"raise"`.
- **Dispatch.** `stdlib.dispatched` gains `<generator>` with `iter`, `next`,
  `close`, `enter`, and `exit(error: Exception | None)`, generalizing
  `dispatched` to take a method table.

## Test plan

- `tests/unit/parser_test.lua`: `yield x` parses as a statement; bare `yield`
  reports "expected an expression".
- `tests/unit/check_test.lua`:
  - an `int` annotation on a generator reports the annotation error;
  - `return 1` in a generator reports "a generator cannot return a value";
  - `yield "a"` in an `Iterator[int]` generator reports "expected int,
    received str";
  - `yield` in `finally` reports the finally error;
  - a nested generator narrowing a captured `int | None` before a `yield`
    reports the `+` error after it;
  - a generator without a `return` passes the every-path check.
- `tests/programs/generators.wlo` and `.out`:
  - the body prints on the first `next`, not at the call; locals persist
    across yields;
  - `for` over a `Generator[int]`, an `Iterable[str]` generator method, a
    generic `Iterator[T]` generator, and `yield None` in `Iterator[int | None]`;
  - bare `return` ends the generator; after exhaustion `next` raises
    `StopIteration` again;
  - a body `ValueError` propagates, and the generator then raises
    `StopIteration`; `StopIteration` escaping the body becomes the
    `RuntimeError`;
  - a generator calling `next` on itself raises `generator already running`;
  - `close()` on a suspended generator runs its `finally` and skips an
    `except Exception` handler; closing an unstarted generator never prints its
    first line, and `next` then raises `StopIteration`.
- `tests/programs/generator_traceback.wlo` and `.err`: an uncaught exception
  from a generator body lists the generator frame and the frames of the
  `for` loop that advanced it.
- `make test` passes.

## Implementation plan

1. Parser `Yield`; bind `fn.generator` and call counting.
2. Check: annotation, returns, yields, finally, captured narrowing.
3. Runtime: generator object, yield, next, close, iter, enter, exit, the
   cancel value in `__wlo_try`.
4. `stdlib.dispatched` `<generator>`; lower and emit generator bodies, `Yield`,
   and the `cancel` re-raise in `Try`.
5. Tests, then check off the task in `agents/todo.md`.
