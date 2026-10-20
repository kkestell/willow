# `with` statements

## Goal

First task of the context managers milestone (spec §8 Scoped cleanup):

- `with manager as target, other as (a, b): body` requires each manager to
  satisfy `ContextManager[T]`. Its expression is evaluated once, `enter()`
  runs, and the result is assigned to the optional target, a name or a
  parenthesized tuple pattern.
- Managers enter left to right and exit right to left, like nested `with`
  statements. If a later entry fails, the earlier managers still exit, and a
  manager whose entry failed does not.
- After successful entry, `exit(error)` runs exactly once when control leaves
  the body: with the pending exception, or `None` for normal completion,
  `return`, `break`, `continue`, and generator closing. Return values are
  evaluated before exit. An exception from `exit` replaces the pending
  exception or transfer.
- Targets follow normal assignment rules and stay local after the statement;
  the statement adds no scope.

`enter`/`exit` on library resources and the example rewrites are the next
task.

## Related code

- `compiler/parser.lua`: `with` is in `unsupported`; `for` shows target parsing
  (`parse_target`, `check_targets`).
- `compiler/ast.lua`: `assignments`, which bind uses to collect local symbols.
- `compiler/bind.lua`: `resolve_block` (statements, `resolve_targets`,
  `calls`).
- `compiler/check.lua`: the `For` branch's synthesized `iter_call`/`next_call`,
  `check_method`, `check_pattern`, `method_of`, `forget_captured`, `replace`.
- `compiler/lower.lua`: `Try` lowering (`protect`, `departure`, `resume`),
  `unpack_pattern`, `spill`.
- `compiler/emit.lua`: `Try` emission, which keeps the block's departure in
  `__wlo_code<i>` and its exception in `__wlo_value<i>`; `function_body`.

## Decisions

- **Syntax.** `With` holds `items` (`manager`, optional `target`) and `body`.
  A target is `parse_target()`: a name or a parenthesized tuple pattern, since
  commas separate managers. Targets across items are checked for duplicates
  like `for` targets.
- **Binding.** `ast.assignments` visits `With` targets and its body. Bind
  resolves each manager and target, counting `enter` and `exit` as calls, so
  loops forget captured narrowing.
- **Checking.** For each item: the manager's type `M` must have an `enter`
  method whose result `T` makes `M` assignable to `ContextManager[T]`, or the
  statement reports "type M is not a context manager". Check stores
  `enter_call` and `exit_call` as checked `MethodCall`s whose receiver is a
  shared `ManagerRef` node. The `exit` argument is a `PendingError` node of
  type `Exception | None`. The target is checked with `check_pattern` against
  `T`. Both calls forget captured narrowing. The body is checked in the
  enclosing loop context; its end state and transfers are the statement's.
- **Lowering.** One `Try` per item, nested, with no handlers:
  - the manager is stored in a function-level `__wlo_m<i>` local (`Manager`
    node), because the exit runs after the body's temporaries are reused;
  - `enter` runs and its result goes to the target, before the `Try`;
  - the protected body is the next item's lowering, or the statement body;
  - the `finally` body evaluates `exit_call`, whose `PendingError` reads the
    `Try`'s state as `__wlo_code<i> == "raise" and __wlo_value<i> or nil`.
  The existing `Try` machinery then gives departures, return values evaluated
  before exit, the "cancel" departure as `None`, and exit errors replacing the
  pending exception. `protect` accepts a function as well as a block.
- **Emission.** `function_body` declares `__wlo_m1` and up next to the
  temporaries; `Manager` and `PendingError` are new expression kinds.

## Test plan

- `tests/unit/parser_test.lua`: `with a as x, b as (y, z):` parses with two
  items; `with a as (x, x):` reports the duplicate target.
- `tests/unit/check_test.lua`: `with 1:` reports "type int is not a context
  manager"; a target typed from `enter`'s result (`s: int = x` after
  `with Manager() as x` where `enter` returns `str` reports the mismatch); the
  target is definitely assigned after the statement; an `exit` whose parameter
  is not named `error` makes the class no manager.
- `tests/programs/with_statements.wlo` and `.out`, with a logging `Resource`
  class (`enter` logs and returns its name, `exit` logs the error message or
  `None`):
  - normal completion, two managers entering and exiting in order, and a
    tuple-pattern target;
  - an exception in the body reaching `exit` and propagating to an outer
    `except`;
  - `return` (with its value evaluated before exit), `break`, and `continue`
    leaving the body with `exit(None)`;
  - a failing second `enter`: the first manager exits with the error, the
    second never does;
  - an exception from `exit` replacing a body exception and replacing a
    `return`;
  - a generator suspended inside `with`, closed: its `exit` receives `None`;
  - a generator used as a manager: `with gen() as g:` iterates it, and exit
    closes it (its `finally` runs).
- `make test` passes.

## Implementation plan

1. Parser, `ast.assignments`, and bind.
2. Check: `With`, `PendingError`.
3. Lower and emit: `Manager`, `PendingError`, nested `Try` per item, the
   function-level manager locals.
4. Tests, then check off the task in `agents/todo.md`.
