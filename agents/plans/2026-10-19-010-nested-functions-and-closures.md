# Nested functions and closures

## Goal

Continue the function-values milestone in `agents/todo.md` (spec §3 Functions,
§9 Scope, Captures, Narrowing).

- A `def` statement inside a function defines a nested function. It binds its
  name, a local of the enclosing function, when the statement runs.
- The nested function reads variables of enclosing functions as shared
  bindings, separate per enclosing call; a loop variable is one binding
  reused by the loop.
- It may call itself by name. Every other captured variable must be
  definitely assigned where the `def` runs.
- Captured variables start the closure body with their full types, and every
  call removes the narrowing of captured variables.
- Nested functions compile to Lua closures. Their traceback frames are named
  `outer.inner`.
- `nonlocal` and lambdas are the next task, so nested functions cannot rebind
  outer variables yet; assignment creates a local of the nested function.

## Related code

- `compiler/parser.lua` `parse_statement` — rejects `def` with "nested functions are not supported"; `parse_function`.
- `compiler/ast.lua` `assignments` — collects the names a function body assigns.
- `compiler/bind.lua` `collect_symbols`, `resolve_function` (`scope` lookups), and `resolve_signature` and `check_default`, now inside or after `M.bind`.
- `compiler/check.lua` `check_function`, `assign`, `narrow`, the `Binary` `and`/`or` facts, and the call branches.
- `compiler/lower.lua` `lower_function` and `lower_statement`.
- `compiler/emit.lua` — the top-level function loop, `fn_name` for line-map frame names, and `Set` emission.

## Decisions

- Tree: `def` in a body parses with `parse_function` into a `FunctionDef`
  statement with `fn`, `name`, and `span`. `ast.assignments` visits it, so its
  name becomes a local of the enclosing function. It does not descend into
  nested bodies, which are separate scopes.
- Bind:
  - Each symbol records its `owner` function, and `collect_symbols` checks
    `rawget`, so a nested function's assignments always make its own locals.
  - A nested function's scope table falls back to the enclosing scope through
    a metatable `__index`, so lookups find the nearest binding.
  - When a `Name` resolves to a symbol owned by another function, the symbol is
    marked `captured`. It is added, with the first reference's span, to
    `captures` of every function from the current one up to its owner.
  - A `FunctionDef` sets `parent` and `module` and gets
    `type_name = <enclosing name>.<name>`, where a method's enclosing name is
    `Class.method`. Its signature and defaults resolve like file-level ones
    (`resolve_signature` and `check_default` move to module level), and it
    gets `value_type = types.func(nested)`.
  - Its body then resolves with the chained scope.
- Check:
  - `check_function(fn, entry)` starts from an entry state.
  - At a `FunctionDef`, every capture other than the function's own name must
    be definitely assigned in the current state. Otherwise the existing
    "variable 'x' may be used before assignment" is reported at the
    reference.
  - The def's name symbol then takes `value_type` like an assignment. The
    nested body is checked with an entry state mapping each captured symbol to
    its full declared type, including its own name for recursion.
- Narrowing after calls:
  - A new `forget_captured(state)` resets every captured symbol in `state`
    to its declared type. `check_expression` calls it after `Call`,
    `CallValue`, and `MethodCall`, and counts calls.
  - When the right operand of `and` or `or` made a call, captured symbols are
    dropped from the left operand's facts, and the outer state is reset too.
    The right operand runs in a narrowed copy of that state.
- Lowering: a `FunctionDef` lowers to `Set(Local symbol, Closure fn)`, where
  `fn` is `lower_function(nested)`. Captured variables are ordinary
  function-level Lua locals of the enclosing function, so Lua upvalues give
  shared bindings per call, and a loop variable is one binding reused across
  iterations.
- Emission: a `Set` of a `Closure` writes `target = function(params)`, the
  nested function's locals and body, and `end`. The function body emission is
  shared with top-level functions. While emitting the closure, `fn_name` is
  `<enclosing frame>.<name>`, so its lines map to that frame name.

## Test plan

- `tests/unit/parser_test.lua`: a nested `def` parses as `FunctionDef`.
- `tests/unit/bind_test.lua`:
  - a nested function's `Name` resolves to the outer symbol and marks it
    `captured`;
  - a nested assignment to an outer name creates a nested local;
  - a capture two levels deep is in both functions' `captures`.
- `tests/unit/check_test.lua`:
  - capturing a variable assigned after the `def` reports "may be used before
    assignment";
  - inside the closure, a captured `int | None` that the outer function
    narrowed is still `int | None`;
  - after a call, an outer captured variable's narrowing is gone;
  - `x is not None and f()` drops the fact for a captured `x`.
- `tests/programs/closures.wlo` and `.out`:
  - a counter-like closure reading an outer variable that the outer function
    rebinds after creating it;
  - separate calls to the outer function make separate bindings;
  - closures created in a loop all see the loop variable's last value;
  - a recursive nested function;
  - a nested function returned as `typing.Callable` and called after its
    outer call returns;
  - nested functions with defaults and keyword arguments;
  - a nested function in a method.
- `tests/programs/closure_traceback.wlo` and `.err`: an exception raised in a
  nested function shows `in outer.inner at ...` then `called from outer`.

## Implementation plan

- `compiler/parser.lua`: `FunctionDef` statements.
- `compiler/ast.lua`: visit `FunctionDef` in `assignments`.
- `compiler/bind.lua`: `owner`, `rawget`, scope chaining, captures, and
  `FunctionDef` resolution; move `resolve_signature` and `check_default` to
  module level.
- `compiler/check.lua`: entry state in `check_function`; `FunctionDef`;
  `forget_captured` and the `and`/`or` fact rule.
- `compiler/lower.lua`: `FunctionDef` and `Closure`.
- `compiler/emit.lua`: shared function body emission; `Closure` in `Set`;
  frame names.
- Tests listed above; `agents/todo.md`: check off the task.
