# Callable types

## Goal

Continue the function-values milestone in `agents/todo.md` (spec §3
Annotations, §4 Assignability and Unions, §5 Function values, §14 `typing`).

- Programs can `import typing` and annotate `typing.Callable[[A, B], R]`.
- A function value or callable converts to a callable type when:
  - it accepts every listed positional argument; parameter types may be
    broader;
  - any extra parameters it has are defaulted;
  - its return type is assignable to `R`.
- At conversion, arguments and results are adapted between float
  representations, and omitted defaults are supplied.
- A call through a callable takes exactly its listed positional arguments.
- A function with a required keyword-only parameter does not convert.
- A union holds at most one callable member.

## Related code

- `compiler/parser.lua` `parse_member` — named types take no arguments today.
- `compiler/stdlib.lua` `provided` — compiler-provided modules.
- `compiler/bind.lua` `resolve_named`, `type_text`, `resolve_type`,
  `default_type`, and the `IsInstance`, module `MethodCall`, and
  `declared_value` paths.
- `compiler/types.lua` `same`, `assignable`, `conflict`, `func`.
- `compiler/check.lua` `CallValue`.
- `compiler/lower.lua` `conversion` and `convert` — the step table that
  `__wlo_convert` applies.
- `compiler/emit.lua` `step_text`.
- `runtime/core.lua` `__wlo_convert`.

## Decisions

- Syntax: a named type may be followed by `[args]`. Each argument is a type, or
  a bracketed list of types parsed as a `TypeList` node. `typing.Callable[[],
  int]` takes no parameters.
- Bind:
  - The provided `typing` module declares `Callable` as
    `{ kind = "Callable", name = "Callable", type_name = "typing.Callable" }`.
    `resolve_named` accepts it.
  - `resolve_type` requires exactly a `TypeList` and a type, reporting
    "typing.Callable expects a list of parameter types and a return type", and
    builds `types.callable(params, result)`.
  - Type arguments on any other named type report "type 'X' does not take
    type arguments".
  - `type_text` names callable types the same way the type does.
  - `typing.Callable` used as a value, called, or tested with `isinstance`
    reports "callable 'typing.Callable' cannot be used as a value", "callable
    'typing.Callable' cannot be called", and "typing.Callable cannot be used in
    isinstance".
- Types:
  - `types.callable` returns
    `{ kind = "callable", params, result, name = "typing.Callable[[A, B], R]" }`,
    compared structurally in `same`.
  - In `assignable`, a callable target accepts:
    - a callable source of the same arity whose parameters accept the
      target's parameter types and whose result is assignable to the target's;
    - a function source whose first `n` parameters are not keyword-only and
      accept the target's parameter types, whose remaining parameters all have
      defaults, and whose return type is assignable to the result.
  - `conflict` counts `callable` with list, dict, and tuple, reporting "a union
    can have only one callable member".
  - Callable types are not comparable or printable.
- Calls: `CallValue` also accepts a `callable` callee. It binds arguments with
  unnamed parameters and noun nil, so keywords report "does not accept keyword
  arguments" and arity is exact. The type is the callable's result.
- Conversion:
  - `conversion(from, to)` gains an `adapt` entry when `from` has a function
    or callable member and `to` has a different callable member and the two
    need adapting. That is when the source has more parameters, or an
    argument or the result changes representation.
  - `adapt` is a lowered `Adapter` node `{ arity, body }`. Its `body` calls an
    `AdapterCallee` with each `AdapterParam` converted from the callable's
    parameter type to the source's. It then appends each extra parameter's
    default, lowered from the default node and converted from its type to the
    parameter's. Finally it converts the call's result to the callable's
    result.
  - Bind's `default_type` records `type` on each default node so lowering
    can convert it. `convert` emits the `convert` helper whenever a step has
    `adapt`.
  - `step_text` writes `adapt = function(__wlo_f, __wlo_p1, ...) return <body> end`.
  - `__wlo_convert` returns `function(...) return adapt(f, ...) end` for a
    Lua function value whose step has `adapt`. It returns other values
    unchanged, so `None` in an optional callable passes through. Nested
    callables adapt through the same step inside an argument or result.
    Tuple positions holding callables adapt through their position steps.

## Test plan

- `tests/unit/parser_test.lua`: `typing.Callable[[int, str], bool]` and
  `typing.Callable[[], int]` annotations parse.
- `tests/unit/bind_test.lua`:
  - the callable type's name;
  - the shape error for `typing.Callable[int]` and bare `typing.Callable`;
  - type arguments on a class;
  - `typing.Callable[[int], int] | typing.Callable[[str], int]` reports
    "a union can have only one callable member";
  - `isinstance(x, typing.Callable)` is rejected.
- `tests/unit/check_test.lua`:
  - a function with a required keyword-only parameter does not convert;
  - an `int`-parameter function does not serve `Callable[[int | None], int]`;
  - a `str`-returning function does not serve `Callable[[], int]`;
  - calls through a callable reject keywords and wrong arity;
  - printing a callable is rejected.
- `tests/programs/callables.wlo` and `.out`:
  - passing a function with an extra defaulted parameter and one with a
    defaulted keyword-only parameter, so the defaults are supplied;
  - a function taking `int | None` serving `Callable[[int], ...]`;
  - float adaptation of an argument (`float` into an `int | float` parameter)
    and of a result (`float` out as `int | float`), shown with
    `isinstance(..., float)`;
  - a callable-to-callable conversion;
  - a `list[typing.Callable[[int], int]]` of different functions called in a
    loop;
  - an optional callable narrowed with `is not None`;
  - a higher-order callable whose parameter is itself a callable.

## Implementation plan

- `compiler/parser.lua`: type arguments and `TypeList` on named types.
- `compiler/stdlib.lua`: the `typing` module.
- `compiler/types.lua`: `callable`; `same`, `assignable`, and `conflict`.
- `compiler/bind.lua`: `resolve_named`, `type_text`, and `resolve_type` for
  `Callable`; the value, call, and `isinstance` errors; `type` on default
  nodes.
- `compiler/check.lua`: callable callees in `CallValue`.
- `compiler/lower.lua`: `adapt` in `conversion`, `lower_default`, and `convert`.
- `compiler/emit.lua`: `Adapter`, `AdapterCallee`, `AdapterParam`, and `adapt` in `step_text`.
- `runtime/core.lua`: `adapt` in `__wlo_convert`.
- Tests listed above; `agents/todo.md`: check off the task.
