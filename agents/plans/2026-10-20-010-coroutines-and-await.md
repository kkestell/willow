# Coroutines and `await`

## Goal

First slice of the async milestone (spec §1, §3, §5, §8, §15):

- `async def` declares file-level functions, nested functions, methods, and
  protocol methods. A function annotated `-> T` has return type
  `Coroutine[T]`, and its body returns values assignable to `T` under §9's
  return rules. An async protocol method is exactly a method returning
  `Coroutine[T]`.
- `Coroutine[T]` is an annotation: an opaque, invariant generic type with no
  methods, at most one specialization per union, and no `isinstance` test.
- `await expression` sits at precedence level 8, with a postfix operand, so
  `await -x` and `await await c` are syntax errors. It requires a
  `Coroutine[T]` and produces `T`. It is allowed only in an async body,
  including its `finally` clauses, and not in nested synchronous functions,
  lambdas, or generators. An async body cannot contain `yield`.
- An expression statement cannot discard a `Coroutine[T]` or a union with a
  `Coroutine` member. A value typed by a type parameter may be discarded.
- Calling an async function binds its arguments and runs none of its body.
  Awaiting consumes the coroutine and runs the body inline; consuming it again
  raises `RuntimeError` `coroutine was already awaited or started`.
- Async `main` and async `test_*` functions run as the root task.

`aio.Task`, `aio.TaskGroup`, `async with`, and `aio.sleep` are later slices.
Nothing suspends yet.

## Related code

- `compiler/lexer.lua`, `compiler/parser.lua`: reserved words, `unsupported`,
  type names, `parse_unary`, `parse_function`, statement and declaration
  dispatch.
- `compiler/stdlib.lua`: built-in protocols and native records.
- `compiler/bind.lua`: `resolve_named`, `resolve_signature`, the `Yield`
  statement and `calls` count, `main` and test signature checks.
- `compiler/check.lua`: `check_function`'s return type, call narrowing, and
  `CallStmt`.
- `compiler/lower.lua`, `compiler/emit.lua`: `is_pure`, `lower_node`,
  `function_body`, the `__wlo_run` call.
- `runtime/core.lua`: the generator helpers.

## Decisions

- **Type.** `stdlib.coroutine` is a native generic record named `Coroutine`
  with no fields or methods. Specializations reuse `types.generic`, so
  invariance and the one-specialization union rule come for free.
  `resolve_named` finds it by its reserved name.
- **Signatures.** The parser marks `fn.async`. `resolve_signature` wraps an
  async function's resolved return type in `Coroutine`, so calls, function
  values, protocol matching, and inference see `Coroutine[T]` with no other
  changes. `bind.result_type(fn)` gives `T` for return checking and for the
  `main` and test signature rules.
- **`await`.** An `Await` node. Bind rejects it outside async functions and
  counts it as a call. Check passes `Coroutine[expected]` down for inference,
  requires a coroutine operand, and forgets captured narrowing as after a
  call. Lowering makes it a `__wlo_await(c, site)` helper call.
- **Discard rule.** `CallStmt` also holds an `Await`. Check reports
  `cannot discard a value of type X; a discarded coroutine never runs` when a
  member of the statement's type is a coroutine.
- **Run time.** As the review recommends, a coroutine is not its own Lua
  coroutine. `__wlo_coroutine(body)` returns
  `{ __wlo_record = "<coroutine>", body = body }`, where `body` closes over
  the bound arguments and is emitted like a generator body.
  `__wlo_consume(c, site)` returns the body and clears it, or raises the
  `RuntimeError`. `__wlo_await` calls the consumed body, so it runs in the
  awaiting task's Lua coroutine and frames read like ordinary calls. A
  group's `start` will use `__wlo_consume` too.
- **Root task.** The emitter passes `function() __wlo_root(main()) end` to
  `__wlo_run` for an async `main`, and the same for an async test.
  `__wlo_root` runs the body in a new Lua coroutine under `xpcall` and raises
  any error again, so frames stop at the task root. The scheduler in
  `runtime/aio.lua` replaces it in the next slice; the interface was sent to
  agent loop.

## Test plan

- `tests/unit/parser_test.lua`: async functions, methods, protocol methods,
  and nested functions; `await` precedence; `await -c` and `await await c`;
  `await` as a statement.
- `tests/unit/check_test.lua`: return checking and the every-path rule in
  async bodies; async `main` returning `int`; `yield` in an async body;
  `await` in a sync function, a lambda, and a nested sync function; `await`
  in `finally`; awaiting an `int`; invariance; the union restriction;
  `isinstance`; the discard rule for a coroutine, a union, and an awaited
  coroutine of a coroutine, with a type parameter exempt; async protocol
  sugar; captured narrowing removed by an await.
- `tests/programs/coroutines.wlo`: argument evaluation before the body, file
  level, generic, nested, and method coroutines, async and coroutine-returning
  protocol methods, function values, exceptions through awaits, await in
  `finally`, the already-awaited error through an alias, an unused coroutine.
- `tests/programs/coroutine_traceback.wlo`: frames through recursive awaits of
  a method, ending at `main`.
- `tests/unit/cli_test.lua` and `tests/suites/failing`: a passing and a
  failing async test, and an async test returning `int`.
- `make test` passes.

## Implementation plan

1. Lexer and parser.
2. `Coroutine` in stdlib; bind signatures, `await`, `yield`, `main`, tests.
3. Check `await`, returns, and the discard rule.
4. Runtime helpers; lower and emit.
5. Tests; tick the slice in `agents/todo.md`.
