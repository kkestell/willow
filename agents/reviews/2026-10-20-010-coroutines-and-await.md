# Coroutines and `await`

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-010-coroutines-and-await.md`:
`async def` and `await` in `compiler/lexer.lua` and `compiler/parser.lua`, the
`Coroutine` native record and `has_coroutine` in `compiler/stdlib.lua`,
`resolve_signature`, `result_type`, the `Await`, `Yield`, and `isinstance`
rules and the `main` and test signatures in `compiler/bind.lua`, the `Await`
branch, return type, and discard rule in `compiler/check.lua`, `is_pure` and
the `Await` lowering in `compiler/lower.lua`, `function_body` and the root task
in `compiler/emit.lua`, the coroutine helpers in `runtime/core.lua`, and the
new unit, program, and CLI tests. The review read them against spec §1, §2,
§3, §5, §8, §9, §12, and §15, and traced how async functions combine with
methods, nested functions and closures, `nonlocal`, lambdas, generic functions
and classes, generic and non-generic protocols, protocol-to-protocol
assignment, generators, exceptions and tracebacks, `try`/`finally`, `with`,
`break` and `return` through `finally`, imported modules, `isinstance` over
unions holding a coroutine, short-circuit operators, and `sys.exit`.

The protocol converter crash later seen with the hand-built `Coroutine`
record (no `self_type` or `type`) cannot happen at this slice: `converters` in
`compiler/lower.lua` only visits module records, native declarations of
imported library modules, and `stdlib.dispatched`, and `stdlib.coroutine` is in
none of them. A program with a protocol method call, a `Coroutine` annotation,
and imported library modules compiled and ran.

Gaps:

- Suspension, task groups, and the scheduler are later slices; `__wlo_root`
  was reviewed only as the one-resume stand-in the plan describes.

## Summary

| ID | Severity | Category      | Fix  | Title                                                     |
| -- | -------- | ------------- | ---- | --------------------------------------------------------- |
| F1 | Low      | Documentation | Deferred | Ticked todo item describes a runtime model not implemented |

## F1. Ticked todo item describes a runtime model not implemented

Low · Documentation · Deferred · `agents/todo.md:20`

The slice ticks the bullet "Each coroutine a Lua coroutine emitted like a
generator body". The implementation follows the plan and the async design
review instead: a coroutine is a table holding its body as a closure, and only
the root task (later, each task) is a Lua coroutine. The later async slices
read this list, so the ticked text misstates the model they build on. The work
log's first follow-up item records the mismatch rather than resolving it.

### Evidence

`__wlo_coroutine` in `runtime/core.lua` returns
`{ __wlo_record = "<coroutine>", body = body }`, and `__wlo_await` calls the
consumed body directly; the compiled `coroutine_traceback.wlo` shows
`return __wlo_coroutine(function() ... end)` with no `coroutine.create` outside
`__wlo_root`.

### Fix

Left unchanged in this slice. The next slice that edits the list,
`2026-10-20-014-aio-sleep-and-root-task`, rewords the item to "Each task a Lua
coroutine; each Willow coroutine a deferred body emitted like a generator
body", which matches the implementation; changing it here would conflict with
that edit.

## Checks run

- Scratch programs for nested async closures with captures and `nonlocal`,
  async methods of plain and generic classes, generic async functions
  (including inference from an expected type and explicit type arguments),
  bound async methods, lambdas returning coroutines, keyword-only parameters,
  generic and non-generic protocols declared with `async def` or
  `-> Coroutine[T]`, protocol-to-protocol assignment, protocol and union
  results converted through `await`, generic protocols with `float` and
  `int | float` results, `Coroutine` in aliases, generic holders, and unions
  narrowed by `isinstance`, generators inside async functions and async
  functions inside generators, imported async functions, classes, and
  protocols, `with` and `try`/`finally` around raising awaits, `return` and
  `break` through `finally` with awaits, short-circuit `and` around `await`,
  `sys.exit` in a coroutine, and deep recursion through awaits; each behaved
  as the spec requires and matched the synchronous equivalent where one
  exists.
- Rejections confirmed: `print`, `str`, f-string formatting, `==`, `in`, `is`,
  dictionary keys, fields, and methods on a `Coroutine`; bare and
  wrong-arity `Coroutine`; `Coroutine[int]()`; `await` of `None`, tuples,
  function values, and `int`; `await` in defaults, assignment targets, and
  loop targets.
- `make test`: 340 passed, 0 failed.

## Verdict

The parser, binder, checker, lowering, emitter, and runtime helpers implement
the plan and spec §1, §3, §5, §8, §9, §12, and §15 for this slice, and async
functions combine correctly with the rest of the language in every case
tried. F1 is a stale description in the todo list.
