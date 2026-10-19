# Generic call inference

## Goal

Continue the generics milestone in `agents/todo.md` (spec §3 Type
parameters).

- A call of a generic function without type arguments, such as `first(xs)`,
  infers them from its arguments and, for parameters the arguments leave open,
  from the expected result.
- The substitution must be unique. Inference never invents a union to
  reconcile different argument types.
- A type parameter left undetermined is an error.

## Related code

- `compiler/check.lua` `specialize` (reports "needs type arguments" today), the `Call` and `CallValue` branches, `evaluation_order`, and the `Lambda` branch.
- `compiler/types.lua` `has_typevar`, `substitute`, `assignable`.

## Decisions

- Candidates: a new `infer_call` in `check_function` checks the call's
  arguments in evaluation order. An argument whose parameter type mentions
  none of the callee's type parameters gets that type as its expected type;
  the others are checked with no expected type. Each argument's type is then
  matched against its parameter type by `collect`, which records candidate
  types per type parameter:
  - a parameter `T` takes the argument type;
  - `T | None` takes the argument type without `None`, and nothing for `None`
    alone;
  - lists, dicts, and tuples match element by element;
  - a callable parameter matches a callable or function argument's
    parameters and result.
  Omitted arguments are the defaults `bind_args` filled in, so they count too.
- Lambda arguments: a lambda whose parameter type mentions the callee's type
  parameters is checked after the other arguments. Its expected type is the
  parameter type with the candidates chosen so far substituted.
  - If that callable's parameters still mention an undetermined type
    parameter, report "cannot infer the parameter types of this lambda".
  - Otherwise the lambda is marked `infer_result`. The `Lambda` branch then
    takes its parameter types from that callable, infers its result from the
    body, and has the type `typing.Callable[[params], body type]`, which is
    matched like any other argument.
- Choosing: each type parameter takes the one candidate that every other
  candidate is assignable to, so `int` and `int | None` give `int | None`. With
  no such candidate, report "cannot infer type parameter 'T' of 'f' from int
  and str", naming the first two candidates that conflict.
- Expected result: type parameters with no candidates from the arguments take
  candidates from matching the return type against the expected type. That
  way `y: int | None = first([1])` keeps `T = int`, while
  `xs: list[int] = empty()` infers `T = int`.
- A type parameter still without candidates reports "cannot infer type
  parameter 'T' of 'first'".
- After choosing, every argument is checked against its substituted parameter
  type with `expect_type`, so invariance errors and float conversions work as
  for explicit calls. The chosen types become `node.type_args`. `specialize`
  only checks explicit type arguments, and `infer_call` handles calls without
  them in both `Call` and `CallValue`.
- `types.mentions(t, set)` generalizes `has_typevar` to count only the type
  parameters in `set`.

## Test plan

- `tests/unit/check_test.lua`:
  - `pair_same(1, 'a')` for `def pair_same[T](a: T, b: T)` reports the
    conflict error;
  - `empty()` with no expected type reports the undetermined error;
  - `xs: list[str] = first_list([[1]])` reports an assignability error;
  - a lambda whose parameter type depends on nothing else reports "cannot
    infer the parameter types of this lambda".
- `tests/programs/generics.wlo` and `.out`:
  - `first(xs)` for `list[int]` and `list[str]`;
  - `pair_same(1, maybe)` with `maybe: int | None` widening to `int | None`;
  - `pick(None, 5)` through `T | None`;
  - `xs: list[int] = empty()` from the expected result;
  - `y: int | None = first([1])`;
  - `map_list(lambda x: x * 2, [1, 2])` inferring both type parameters
    through the lambda;
  - a nested generic `def` called without type arguments.

## Implementation plan

- `compiler/types.lua`: `mentions`.
- `compiler/check.lua`: `collect`, choosing, `infer_call`, and its use in
  `Call` and `CallValue`; `infer_result` in the `Lambda` branch.
- Tests listed above; `agents/todo.md`: check off the task.
