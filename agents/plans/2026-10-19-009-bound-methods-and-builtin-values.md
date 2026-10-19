# Bound methods and built-in function values

## Goal

Continue the function-values milestone in `agents/todo.md` (spec §5 Function
values). Reading a declared method from a class value, as in `counter.add`,
produces a bound method. The receiver is evaluated once and kept, so later
calls see its current fields. A bound method keeps its full call signature, as
function values do. Built-in functions, such as `len` and `str`, and
standard-library module functions, such as `time.time` and `fs.exists`,
become values where an expected callable type fixes their signature.

## Related code

- `compiler/types.lua` `func` and `serves` — function value types and their conversion to callables.
- `compiler/bind.lua` `resolve_signature` (methods get `class` and `module`), `declared_value`, and the `Name` path that rejects built-ins as values.
- `compiler/check.lua` `Field` / `field_type`, `class_method`, `CallValue`, and the builtin `Call` checks.
- `compiler/lower.lua` `adapter`, `Field`, `FunctionValue`.
- `compiler/emit.lua` `step_text` and its adapter emission.
- `runtime/core.lua`.

## Decisions

- Bound method types: `types.func(decl, bound)`. A bound type has
  `bound = true` and is named `function C.add`, using the class's
  `type_name`. Bind gives each method `value_type = types.func(method, true)`.
  `types.params(t)` returns a function type's parameters without `self` when
  bound. `serves`, `CallValue`, and the lowering adapter use it in place of
  `fn.params`.
- Check: a `Field` read on a non-native class value whose class declares that
  method takes `node.method` and the method's `value_type`. Fields and methods
  never share names, so nothing is ambiguous. Unions still need narrowing
  first, and native and collection methods stay non-values.
- Lowering: such a `Field` lowers to the pure helper
  `bind(receiver, FunctionValue(method))`. `__wlo_bind` returns
  `function(...) return method(receiver, ...) end`, so the receiver is
  evaluated once at the read.
- Built-in values: bind turns a bare name of a built-in, or a field of a
  provided module that names one of its functions, into a `BuiltinValue` node
  with `target` and `name`. `range` and `isinstance`, which have no ordinary
  parameters, keep "function 'range' cannot be used as a value". In check,
  a `BuiltinValue` needs an expected type with a callable member, else it
  reports "function 'len' needs an expected callable type". The value is
  checked by building a synthetic `Call` of the built-in whose arguments are
  `Typed` placeholder nodes of the callable's parameter types. That call goes
  through the ordinary `Call` checks, so arity, argument types, and the
  `any`-parameter rules apply unchanged. Its result must be assignable to the
  callable's result, reported as "expected R, received T". The node's type is
  the callable member, and the checked call is kept as `node.call`.
- Lowering a `BuiltinValue`: the synthetic call is lowered with each `Typed`
  placeholder lowering to `AdapterParam i`. Its result is converted to the
  callable's result, and the whole becomes a lowered `Function` node
  `{ arity, body }`. `emit` writes it as
  `function(__wlo_p1, ...) return <body> end`, the same parameter naming as
  adapters. Placeholders never call anything, so the body is one expression.
  Runtime failures inside report at the value's own site.

## Test plan

- `tests/unit/check_test.lua`:
  - `x = len` reports "function 'len' needs an expected callable type";
  - `f: typing.Callable[[int], int] = len` reports "'len' cannot be applied
    to int";
  - `f: typing.Callable[[str], str] = len` reports "expected str, received int";
  - `x = range` keeps its error;
  - `c.n` on a field and `c.m` on a method both work, while `c.missing`
    still reports "class C has no field 'missing'".
- `tests/unit/bind_test.lua`: `len` and `time.time` as values bind to
  `BuiltinValue`.
- `tests/programs/bound_methods.wlo` and `.out`:
  - a bound method that reads its receiver evaluates the receiver once (a call
    that prints) and sees later field changes;
  - a bound method called with keywords and a default;
  - a bound method passed as `typing.Callable`;
  - `len`, `str`, and `print` as callables;
  - `time.time` as `typing.Callable[[], float]`;
  - `fs.exists` as `typing.Callable[[str], bool]` on a missing path;
  - `int` as `typing.Callable[[str], int]` raising `ValueError` on bad input.

## Implementation plan

- `compiler/types.lua`: `bound` in `func`; `params`; `serves` uses `params`.
- `compiler/bind.lua`: method `value_type`; `BuiltinValue` for built-in names
  and provided-module functions.
- `compiler/check.lua`: bound method reads in `Field`; `CallValue` uses
  `types.params`; `BuiltinValue` with its synthetic call; `Typed` nodes.
- `compiler/lower.lua`: `Field` with a method; `BuiltinValue`; `Typed`
  placeholders; `adapter` uses `types.params`.
- `compiler/emit.lua`: the `Function` node.
- `runtime/core.lua`: `__wlo_bind`.
- Tests listed above; `agents/todo.md`: check off the task.
