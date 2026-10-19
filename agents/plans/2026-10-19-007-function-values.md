# Declared functions as values

## Goal

Start the function-values milestone in `agents/todo.md` (spec §5 Calls, §5
Function values and lambdas, §9). Naming a file-level function, as in
`f = add`, or a module-qualified one, as in `g = geometry.area`, produces a
function value. Its inferred type keeps the declaration's whole call
signature: parameter names, defaults, and keyword-only requirements. Any
expression of function type can be called: `f(1)`, `(add)(1)`,
`handlers[0](x)`. A local that hides a declaration of the same name is called
as a value. Function values cannot be compared with `==`, printed, or tested
with `isinstance`.

## Related code

- `compiler/parser.lua` `parse_postfix` — reports "call target must be a function name" for `(` after a non-name.
- `compiler/bind.lua` `resolve_expression` — `Name` rejects declarations as values. `Call` resolves only declarations and rejects locals ("cannot call local variable"). `Field` on a module path errors through its object. `declare` assigns `type_name`.
- `compiler/types.lua` `same`, `key` — types by kind; records are compared by identity.
- `compiler/check.lua` `Call` and `bind_args`.
- `compiler/lower.lua` `Call` lowering, `is_pure`, `lower_operand`'s spill list.
- `compiler/emit.lua` `function_name` and the `Call` expression.

## Decisions

- Type: `types.func(decl)` returns `{ kind = "function", fn = decl, name = "function " .. decl.type_name }`.
  - Bind's `declare` gives each declared function a `type_name`, the same way
    it does for records, and stores the type as `decl.value_type`.
  - A function type is nominal, compared by identity like a record. Calls
    through it bind arguments with the declaration's own parameters, so its
    defaults and keyword-only rules apply. `same` treats `function` like
    `record`, and union `key` matches it by `fn`.
  - It is neither comparable nor printable, so `==`, `print`, `str`, and
    f-strings reject it with the existing messages. It cannot be named in
    `isinstance`.
- Function values: bind turns a `Name` that names a file-level function (no
  local hides it) into a `FunctionValue` node with `target`. A `Field` whose
  object is an imported module path and whose name is a function of that
  module does the same. Records, aliases, and enums keep their "cannot be
  used as a value" errors. The qualified form now says "class
  'geometry.Point' cannot be used as a value" instead of blaming the module.
  Built-in functions and methods stay rejected; later tasks handle them.
- Calls on values: the parser turns `(` after any postfix expression that is
  not a bare name into a `CallValue` node with `callee` and `args`. Bind
  turns a `Call` whose name is a local into a `CallValue` whose callee is that
  `Name`, so a local hides a declaration of the same name. The
  `isinstance` local check is kept. Check requires the callee type to be
  `function`, reporting "cannot call a value of type T" otherwise, so a union
  must be narrowed first. It binds arguments with
  `bind_args(node, name, callee.fn.params, "parameter")`, where `name` is the
  callee's name if it is a `Name` and the function's name otherwise. The type
  is the function's return type.
- Lowering: `FunctionValue` lowers to a pure `FunctionValue` node that `emit`
  renders with `function_name(target)`. `CallValue` lowers to a `Call` with
  `callee` in place of `target`. The callee is lowered with `lower_operand`
  before the arguments, so it runs first, and the existing `Call` spilling
  applies. `emit` writes `expr(callee)(args)`. `is_pure` treats `CallValue`
  like `Call`.

## Test plan

- `tests/unit/parser_test.lua`: `(f)(1)`, `xs[0](1)`, and `f(1)(2)` parse as
  `CallValue`; `f(1)` stays `Call`.
- `tests/unit/bind_test.lua`: `f = add` gives a `FunctionValue`; `geo.area`
  as a value resolves to the module's function; `geo.Point` as a value reports
  "class 'geo.Point' cannot be used as a value"; a local named `add` makes
  `add(1)` a `CallValue`; `x = len` and `x = c.m` stay rejected.
- `tests/unit/check_test.lua`: `x = 1` then `x(2)` reports "cannot call a
  value of type int"; printing, formatting, and `==` on `f = add` are
  rejected; `f(1)` for a two-parameter function reports "'f' expects 2
  arguments, received 1"; a positional argument through an alias for a
  keyword-only parameter is rejected; `isinstance(f, int)` is rejected.
- `tests/programs/function_values.wlo` and `.out`:
  - aliases called with positional and keyword arguments, with defaults and
    keyword-only parameters;
  - `(double)(4)`, a list, a dict, and a tuple of function values called by
    index;
  - the callee evaluated before its arguments when both print;
  - a local hiding a declaration of the same name;
  - recursion through an alias.
- `tests/modules/qualified/main.wlo` and `.out`: a value of
  `app.util.make` called with a keyword.

## Implementation plan

- `compiler/types.lua`: `func`; `same` and `key` for `function`.
- `compiler/parser.lua`: `CallValue` in `parse_postfix`.
- `compiler/bind.lua`: function `type_name` and `value_type` in `declare`;
  `FunctionValue` for names and module fields; `CallValue` for locals; resolve
  `CallValue` callees and arguments.
- `compiler/check.lua`: `FunctionValue` and `CallValue`.
- `compiler/lower.lua`: `FunctionValue`, `CallValue`, and `is_pure`.
- `compiler/emit.lua`: `FunctionValue` and calls with a `callee`.
- Tests listed above; `agents/todo.md`: check off the task.
