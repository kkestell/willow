# `iter`, `next`, `StopIteration`, and `for` over iterables

## Goal

First task of the extensible iteration milestone (spec §3 Standard protocols,
§8 `for`, §10, §11):

- `StopIteration` is a built-in exception class.
- `iter(value)` calls `value.iter()` and `next(iterator)` calls
  `iterator.next()`. `iter` requires a value satisfying `Iterable[T]` and
  `next` one satisfying `Iterator[T]`. Both take one positional argument.
- `for` over a value of a class, protocol, or bounded type parameter that
  satisfies `Iterable[T]` calls `iter` once, then `next` before each step. Only
  `StopIteration` raised by that `next` call ends the loop; `StopIteration`
  from the body and other advancement errors propagate. The loop does not
  close the iterator, so a loop left early can be resumed.

Built-in values (lists, dicts, strings, bytes, tuples, ranges, files) keep their
current `for` lowering; giving them `iter` methods is the next task, so
`iter([1])` is still rejected here.

## Related code

- `compiler/stdlib.lua`: built-in exceptions and `builtins` (`len` takes
  `"any"`); `M.protocols.Iterable` and `Iterator`.
- `compiler/check.lua`: the `Call` branch (built-in calls), the `MethodCall`
  branch (class, native, protocol, and bounded receivers), the `For` statement,
  and `forget_captured`.
- `compiler/lower.lua`: the `MethodCall` lowering, which records called
  protocols, and the `For` statement, whose `node.iterator` is a helper
  returning a Lua iterator function.
- `compiler/emit.lua`: `For` emits `for _, __wlo_item in <iterator> do`.
- `runtime/core.lua`: the core helpers, always included.

## Decisions

- `check.lua` moves the `MethodCall` branch after the object's check into
  `check_method(node, object, state, expected)`, which returns the call's type.
  The `MethodCall` branch calls it, and so do `iter`, `next`, and `for`, which
  check their receiver themselves.
- `iteration(t)` returns the iterator type and item type of `t`, or nil: the
  result of `t`'s `iter` method (through a bound for a type parameter), that
  iterator's `next` result, and a check that `t` is assignable to
  `Iterable[item]`. `advancement(t)` returns the `next` result of `t` when `t`
  is assignable to `Iterator[result]`.
- `iter` and `next` are built-ins taking `"any"`. After the argument is
  checked, the `Call` node becomes a `MethodCall` on that argument with no
  arguments and goes through `check_method`, so lowering needs nothing new.
  An unsuitable argument reports "'iter' cannot be applied to T" (and
  likewise for `next`), matching `len`.
- `for` over a type with no built-in item type uses `iteration`; otherwise the
  existing "cannot iterate over T" error stands. Check stores two checked
  `MethodCall` nodes on the statement: `iter_call`, on the iterable, and
  `next_call`, whose receiver type is the iterator type. The loop's implicit
  calls forget captured narrowing like any call, so the body starts without it.
- Lowering evaluates `iter_call` into a temporary, then builds the `next`
  callee without calling it: a `Dispatch` for a protocol, the method for a
  class, or the helper for a native type. `node.iterator` is the helper
  `iterate(callee, iterator, site)`.
- `__wlo_iterate` in `runtime/core.lua` returns a Lua iterator function. Each
  step calls `pcall(callee, iterator, site)`; a result continues the loop, a
  `StopIteration` exception ends it, and any other error is raised again
  unchanged, keeping its location and frames.

## Test plan

- `tests/unit/check_test.lua`:
  - `iter(1)` reports "'iter' cannot be applied to int", and `next` on a
    class with `next` but no `iter` reports "'next' cannot be applied to C";
  - `for x in c` over a class without `iter` reports "cannot iterate over C";
  - over an `Iterable[int]` parameter, `s: str = x` in the body reports
    "expected str, received int", and `next(iter(xs))` has type `int`.
- `tests/programs/iteration.wlo` and `.out`, with a `Countdown` iterator that
  raises `StopIteration("")` and a `Bag` iterable whose `iter` returns a fresh
  `Countdown`:
  - `for` over a `Countdown`, a `Bag` twice (fresh traversals), and an
    `Iterable[int]` parameter;
  - `break` out of a loop, then `next` resumes the same iterator and a second
    `for` finishes it;
  - explicit `iter`/`next`, and `next` on an exhausted iterator raising
    `StopIteration`, caught by `except StopIteration`;
  - `StopIteration` raised in a loop body propagates past the loop to an
    enclosing `try`;
  - a `ValueError` from `next` propagates;
  - a generic `total[T: Iterable[int]](xs: T)` loops over its bounded
    parameter;
  - a tuple pattern target over an iterator of `tuple[str, int]`.
- `make test` passes.

## Implementation plan

1. `compiler/stdlib.lua`: `StopIteration`; `iter` and `next` built-ins.
2. `compiler/check.lua`: `check_method`, `iteration`, `advancement`, the
   built-in calls, and `for`.
3. `runtime/core.lua`: `__wlo_iterate`.
4. `compiler/lower.lua`: the `For` iterable path; share the protocol
   registration with `MethodCall`.
5. Tests, then check off the task in `agents/todo.md`.
