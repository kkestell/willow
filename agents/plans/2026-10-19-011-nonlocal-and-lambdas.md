# `nonlocal` and lambdas

## Goal

Finish the function-values milestone in `agents/todo.md` (spec §5 Function
values and lambdas, §9 Captures and `nonlocal`).

- `nonlocal a, b` lets a nested function rebind variables of enclosing
  functions, under the spec's rules.
- `lambda params: expr` is an expression at the lowest precedence. It takes
  its parameter types from an expected callable type, and its body determines
  its return type.
- A parameterless lambda needs no expected type.
- Add Rosetta Code "Higher-order functions" and "Closures/Value capture".

## Related code

- `compiler/parser.lua` `unsupported` (lists `lambda` and `nonlocal`), `parse_expression`, and `parse_statement`.
- `compiler/ast.lua` `assignments`.
- `compiler/bind.lua` `collect_symbols`, `capture`, `resolve_function`, and `FunctionDef` resolution.
- `compiler/check.lua` `FunctionDef` checking, `assigned_symbols`, `display_member`, and `expect_type`.
- `compiler/lower.lua` `FunctionDef`, `spill`, and `lower_function`.

## Decisions

- `nonlocal`:
  - It parses to a `Nonlocal` statement with `names` (each with `name` and
    `span`).
  - `ast.assignments` visits it in order, and `collect_symbols` maps each
    name to the enclosing scope's symbol. Later assignments then rebind that
    symbol rather than creating a local, and the name is not one of the
    function's `locals`.
  - Errors in `collect_symbols`:
    - a name with no binding in an enclosing function, or naming the current
      function's own parameter, reports "nonlocal 'x' must name a variable of
      an enclosing function";
    - a name already assigned earlier in the function reports "'x' is used
      before its nonlocal declaration".
  - The function's `nonlocal_pending` set holds each declared name until
    resolution reaches the `Nonlocal` statement. A `Name` read of a pending
    name reports the same "used before" error.
  - Resolving the statement calls `capture` for each name. The symbol is
    therefore `captured` and must be definitely assigned where the nested
    function is created. Assignments in the nested function check against the
    binding's existing type. Lua upvalues already rebind the outer local.
  - Check's `assigned_symbols` skips `Nonlocal` nodes.
- Lambdas:
  - `parse_expression` parses `lambda` before the `or` level. Parameters are
    names only; the body is a full expression. They become a `Lambda` node
    with `params` and `body`. `lambda` and `nonlocal` leave `unsupported`.
  - Bind builds `node.fn`, a function with `name = "<lambda>"`, `Param`
    nodes without types, and body `{ Return(body) }`. It has `parent`,
    `module`, and a `type_name` like nested defs, and resolves with the
    chained scope through `resolve_function`.
  - Check:
    - The expected type's callable member, if any, is the target.
    - With parameters but no target, report "lambda parameters need an
      expected callable type".
    - With a target of a different arity, report "expected T, received a
      lambda with N parameters".
    - Captures must be definitely assigned, as for `FunctionDef`.
    - The body is checked by `check_expression` in an entry state of captures
      at full types and parameters at the target's types.
    - With a target, the body is checked against the target's result, and the
      lambda's type is the target.
    - Without one, the lambda's type is
      `typing.Callable[[], <body type>]`.
  - Lowering: a `Lambda` lowers like a nested def into a `Closure` set into a
    temporary, which is the expression's value. Creating a closure has no
    effects, so placing it before the rest of the expression changes nothing
    observable. Its frame is named `<enclosing>.<lambda>`.
- Rosetta Code:
  - "Higher-order functions" passes a declared function and a lambda to a
    function taking `typing.Callable[[int], int]`.
  - "Closures/Value capture" builds ten closures, each squaring its own index,
    through a factory function. A loop alone would share its variable's
    binding. It prints the result of calling the closure at index 3.

## Test plan

- `tests/unit/parser_test.lua`:
  - `lambda x, y: x + y` and `lambda: 1` parse;
  - `lambda x: lambda: x` nests;
  - `f(lambda x: x, 1)` parses as two arguments;
  - `nonlocal a, b` parses.
- `tests/unit/bind_test.lua`:
  - `nonlocal` maps a nested assignment to the outer symbol and makes no
    local;
  - unknown names, parameters, use before the declaration, and `nonlocal` in a
    top-level function are rejected.
- `tests/unit/check_test.lua`:
  - `lambda x: x` without an expected callable is rejected;
  - an arity mismatch is rejected;
  - a body that does not fit the expected result reports at the body;
  - a nonlocal assignment of the wrong type is rejected;
  - a lambda capturing a variable assigned later reports "may be used before
    assignment".
- `tests/programs/lambdas.wlo` and `.out`:
  - a counter with `nonlocal`, where two counters are independent;
  - a nested function rebinding a variable that the outer function then
    reads;
  - lambdas passed, returned as `typing.Callable`, and stored in a list;
  - a parameterless lambda without an expected type;
  - a lambda whose `float` result serves `typing.Callable[[], int | float]`;
  - a lambda capturing a loop variable.
- `examples/rosettacode/higher_order_functions.wlo` and
  `closures_value_capture.wlo` with `.out`.

## Implementation plan

- `compiler/parser.lua`: `Lambda` and `Nonlocal`; remove both from `unsupported`.
- `compiler/ast.lua`: visit `Nonlocal` in `assignments`.
- `compiler/bind.lua`: `nonlocal` in `collect_symbols`; `nonlocal_pending`;
  `Nonlocal` and `Lambda` resolution.
- `compiler/check.lua`: `Lambda`; `Nonlocal` (no-op) and `assigned_symbols`.
- `compiler/lower.lua`: `Lambda`; `Nonlocal` lowers to nothing.
- Tests and examples listed above; `agents/todo.md`: check off the task and
  the milestone.
