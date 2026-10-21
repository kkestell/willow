# Task group front end and static checking

## Goal

The compiler front end for task groups and §15's static rule:

- `aio.task_group() -> aio.TaskGroup`. `TaskGroup` has
  `start[T](coro: Coroutine[T]) -> aio.Task[T]` and `cancel() -> None`.
  `aio.Task[T]` has `result() -> T`. Both are opaque native types; `Task` is
  invariant and limited to one specialization per union, like `Coroutine`.
- `await` accepts `aio.Task[T]` and produces `T`.
- `async with expression as name:` is allowed only in async functions,
  accepts only `aio.TaskGroup`, binds an optional name, and adds no scope.
- Static checking across a group (§15): each `await` in a group body, and
  each exit of a nested `async with`, is a possible transfer to the end of
  every enclosing `async with` in the same function that no `finally` clause
  separates from it. The transfer passes intervening `finally` and `with`
  cleanup. Definite assignment, narrowing, and control transfer merge these
  transfers with the body's completion. Awaits and joins remove captured
  narrowing.

Lowering `async with` waits for the group runtime in agent loop's PR #6.

## Related code

- `compiler/stdlib.lua`: the `aio` module, `native_record`, `M.coroutine`.
- `compiler/check.lua`: `method_signature`, `check_method`'s native branch
  and `infer_call`, `check_try`'s `finally` handling, `With`, loops, `Return`,
  `Break`, `Continue`, and `Await`.
- `compiler/parser.lua`, `compiler/ast.lua` (`assignments`),
  `compiler/bind.lua`: statements.
- `compiler/lower.lua`: `Await`, built-in calls, statements.

## Decisions

- **Types.** `aio.Task` is a generic native record with prefix `aio_task`,
  and `aio.TaskGroup` is a native record with prefix `aio_group`, so their
  methods lower to `__wlo_aio_task_result`, `__wlo_aio_group_start`, and
  `__wlo_aio_group_cancel`, the helpers agreed with loop. A native method
  sees its type's arguments substituted, and a native method with `typevars`
  (`start`) infers them like a generic class method.
- **`async with`.** An `AsyncWith` node with `manager`, an optional `Name`
  target, and `body`. Bind rejects it outside async functions and counts its
  join as a call. Check expects `aio.TaskGroup` and assigns the target before
  the body. Plain `with` on a group still reports that it is not a context
  manager.
- **Group frames.** `check_function` keeps a stack of enclosing groups, each
  with the `finally_depth` and loop count at its entry. Each frame collects:
  - `exits`: the state at each await, after its narrowing loss, for every
    group at the current `finally_depth`;
  - `departures`: the state at each `return`, and at each `break` or
    `continue` whose loop encloses the group.
  A `try` updates the states recorded inside it with the same effects its
  `finally` clause has on the fall-through state, or drops them when the
  `finally` clause always transfers. A `with` and a group's join remove
  captured narrowing from them.
- **After a group.** The state after the group joins the body's completion
  with its `exits`, minus captured narrowing. The statement transfers control
  only when the body does and it has no exits. The boundary itself is an
  exit for enclosing groups, with the join of completion, `exits`, and
  `departures`, because a pending outer request can stop a departure there.
- **Lowering.** `await` of a task lowers to `__wlo_aio_await_task`. Until the
  group runtime is on main, lowering reports
  `task groups are not implemented yet` at `async with` and at
  `aio.task_group()`. Without a group no other group or task operation can
  run. The follow-up removes the diagnostic and lowers `async with` through
  `lower_with`'s `Try`, with the finally calling `aio_group_exit`.

## Test plan

- `tests/unit/parser_test.lua`: `async with` with and without a name, and a
  tuple target rejected.
- `tests/unit/check_test.lua`:
  - misuse: `async with` in a sync function, a non-group manager, plain
    `with` on a group, awaiting a group, `Task` invariance, the union rule,
    constructing `aio.Task`;
  - definite assignment: after an await (error), before it (ok), in a
    `finally` on the way out (ok), after an await in a `finally` (ok), after a
    nested group's exit (error), inside the nested group (ok);
  - returns: a return after an await does not satisfy every-path; without an
    await it does, making the next statement unreachable; a nested group's
    exit makes the code after the outer group reachable;
  - narrowing: a transfer's narrowing joins the body's; the join removes
    captured narrowing.
- `tests/programs/task_group_unimplemented.wlo`: the interim diagnostic.
- `make test` passes.

## Implementation plan

1. Declare the types and `task_group`; native method generics; `await` of a
   task.
2. Parse, bind, and check `async with`; group frames and their updates in
   `try`, `with`, loops, and departures.
3. The interim lowering diagnostic.
4. Tests; update `agents/todo.md`.
