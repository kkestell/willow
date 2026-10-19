# Keyword-only parameters

## Goal

Start the keyword-arguments milestone in `agents/todo.md` (spec §3 Functions,
§5 Calls). A bare `*` in a function or method parameter list makes the
parameters after it keyword-only. Keyword-only parameters may be required or
defaulted in any order, a positional argument for one is a compile-time error,
and the rule that a parameter without a default cannot follow one with a
default applies only to positional parameters.

## Related code

- `compiler/parser.lua` `parse_function` and `parse_optional_default` — parse parameters and enforce default ordering.
- `compiler/check.lua` `bind_args` and `check_arity` — match arguments to parameters for functions, methods, constructors, and builtins.
- `tests/unit/parser_test.lua` `show` for `Function` and `Param`.

## Decisions

- Tree: each parameter after the `*` has `keyword_only = true`. No node
  stands for the `*`. Lowering and emission are unchanged, because `bind_args`
  already puts every argument in parameter order and calls pass them
  positionally in Lua.
- Parser errors:
  - A second `*` reports "only one '*' is allowed in a parameter list".
  - A `*` followed by a name, as in `*args`, reports "variadic parameters
    are not supported".
  - A `*` with no parameter after it reports "'*' must be followed by a
    keyword-only parameter".
  - `parse_optional_default` gets no previous parameter for keyword-only
    parameters, so their defaults may come in any order.
- `bind_args`: a positional argument at the index of a keyword-only parameter
  reports "'f' received a positional argument for keyword-only parameter 'c'".
  The required count for `check_arity` covers only positional parameters.
  Required keyword-only parameters that are not given are still reported by
  the existing "is missing argument" check. Builtins and fields have no
  `keyword_only`, so they behave as before.

## Test plan

- `tests/unit/parser_test.lua`: `def f(a: int, *, b: int = 1, c: str) -> None`
  parses, with `b` and `c` keyword-only; `def m(self, *, x: int)` in a class;
  the three `*` errors; `def f(a: int = 1, b: int)` is still rejected.
- `tests/unit/check_test.lua`: `f(1, 2)` for `def f(a: int, *, c: int)` reports
  the positional error; `f(1)` reports "'f' is missing argument 'c'";
  `f(c=2)` reports "'f' is missing argument 'a'"; a method call passes a
  keyword-only argument positionally and is rejected.
- `tests/programs/named_arguments.wlo` and `.out`: a function with required and
  defaulted keyword-only parameters in any order, called with keywords in a
  different order than declared and with defaults omitted; a method with a
  keyword-only parameter.

## Implementation plan

- `compiler/parser.lua`: `*` handling in `parse_function`; mark
  `keyword_only`; skip default ordering for keyword-only parameters.
- `compiler/check.lua`: reject positional arguments for keyword-only
  parameters in `bind_args`; count only positional parameters toward the
  required count.
- `tests/unit/parser_test.lua` (`show` prints `*` before the first keyword-only
  parameter), `tests/unit/check_test.lua`, `tests/programs/named_arguments.wlo`
  and `.out`.
- `agents/todo.md`: check off the task.
