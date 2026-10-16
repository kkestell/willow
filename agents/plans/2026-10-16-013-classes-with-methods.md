# Classes with methods

## Goal

Implement the "Classes with methods" milestone in `agents/todo.md`. Declared
classes, including exception classes, may declare methods after their fields, as
`docs/spec.md` §3 (Classes) and §10 (Exception classes) specify. `v.m(...)`
calls the method of the class of `v` with `v` bound to `self`. The receiver is
evaluated before the arguments, and arguments bind like function arguments.
Diagnostics say "class" instead of "record". The spec and `agents/todo.md` edits
already in the working tree are part of this change.

## Related code

- `compiler/parser.lua`: `parse_function` parses a function. `parse_record`
  parses a class body, which today allows only fields (and `pass` in an
  exception class).
- `compiler/bind.lua`: `declare` collects declarations and reports duplicates
  as `"duplicate " .. kind:lower()`, which produces "duplicate record".
  `M.bind` resolves field, parameter, and return types, checks defaults and
  uniqueness, and calls `resolve_function` on each function. The native types
  (`io.File`, `subprocess.Process`, `cli.Args`, `cli.Parser`,
  `net.Connection`, `net.Listener`) keep a `methods` map of built-in signatures.
- `compiler/check.lua`: `method_signature` looks up methods of built-in types and
  of native types. The `MethodCall` branch of `check_expression` binds and checks
  arguments. `check_function` checks a body. `M.check` checks every function in
  every module. `field_type` reports "record X has no field".
- `compiler/lower.lua`: the `MethodCall` branch of `lower_node` lowers every
  method call to a runtime helper call. `M.lower` lowers `module.functions`.
- `compiler/emit.lua`: `function_name` names entry-module functions as locals
  and other modules' functions through their module table (`module_table`).
  `fn_name` labels traceback frames.
- Tests: `tests/unit/parser_test.lua` (`records`), `tests/unit/bind_test.lua`
  (`records`), `tests/unit/check_test.lua` (`records`,
  `records_across_modules`), `tests/unit/lower_test.lua` (`records`), and
  `tests/programs/*.wlo` with `.out`/`.err` files.

## Decisions

- **AST shape.** A class's methods are ordinary `Function` nodes, kept in source
  order in a new list, `Record.methods`. The first parameter of a method is a
  `Param` named `self` with no type node. Bind sets each method's `fn.class` to
  its class and `fn.module` to its module, and gives `self` the class's type.
  The `self` parameter is then an ordinary parameter, so binding, checking, and
  lowering of method bodies reuse the function code unchanged.
- **Native method tables.** Rename the native types' `methods` map to
  `native_methods`. Otherwise `methods` would be a map on native types and a
  list on declared classes.
- **Method lookup.** User methods are found by scanning `Record.methods`, the
  same way `field_type` scans `fields`. The `MethodCall` check records the found
  method in `node.method`. A missing method keeps the existing message,
  `type X has no method 'm'`, and `p.m` without a call keeps the field error,
  which now reads `class X has no field 'm'`.
- **Generated Lua.** Calls dispatch statically. Each class that has methods gets
  one top-level local table, `__wlo_class_<name>`, where `<name>` is the class's
  `type_name` escaped as `module_table` escapes module names (`_` becomes `__`,
  `.` becomes `_0`). For example, `Counter` becomes `__wlo_class_Counter` and
  `geo.Point` becomes `__wlo_class_geo_0Point`. Methods are emitted as
  `function __wlo_class_Counter.add(self, amount)`, and calls as
  `__wlo_class_Counter.add(counter, 5)`. A `__wlo_` name cannot collide with a
  Willow local, because `mangle` renames user names that start with `__wlo_`.
  So a local named `Counter` cannot hide a method call. Class values stay plain
  tables with no metatables.
- **Traceback names.** A method's frames are labeled `Class.method`, for example
  `in Counter.add at main.wlo:5:9`. The function-level "must return a value"
  diagnostic for a method says `method 'Counter.add'`.
- **Parsing rules and messages.**
  - The first parameter of a method must be the bare name `self`. Otherwise:
    `method 'm' must take 'self' as its first parameter`.
  - An annotation on `self`: `'self' cannot have an annotation`.
  - A field after a method: `fields must come before methods`.
  - Anything else in a class body:
    `class bodies hold only field and method declarations`.
  - `pass` remains valid only as the whole body of an exception class.
- **Name rules, checked in bind.**
  - A repeated method name: `duplicate method 'm'`.
  - A method that shares a field's name: `method 'm' has the same name as a
    field`. This also covers `message` in exception classes, because `message`
    is their first field.
- **Diagnostic wording.** The following messages change:
  - `duplicate record 'X'` becomes `duplicate class 'X'`.
  - `record 'X' cannot be used as a value` becomes
    `class 'X' cannot be used as a value`.
  - `module 'm' has no function, record, or alias 'x'` becomes
    `module 'm' has no function, class, or alias 'x'`.
  - `record X has no field 'f'` becomes `class X has no field 'f'`.
  - `a record name` in parser expectations becomes `a class name`.

  Internal names such as `Record`, `types.record`, and `program.records` stay
  as they are.

## Test plan

- Parser (`parser_test.lua`, `records`):
  - A class with fields and methods, a class with only methods, and an exception
    class with a method all parse.
  - Each of the four parsing errors above is reported.
  - Update the existing expectations for the renamed body message.
- Bind (`bind_test.lua`, `records`):
  - `duplicate method`.
  - A method sharing a field's name.
  - A method named `message` in an exception class.
  - Update the renamed messages, `duplicate class` and `class 'P' cannot be
    used as a value`.
- Check (`check_test.lua`):
  - A method call with positional and keyword arguments and a default.
  - Wrong argument types and counts.
  - A method call on a union that has not been narrowed.
  - `self` typed as its class inside the body.
  - A method body that doesn't return on every path, with the `method
    'P.m'` message.
  - A method call on a class from another module (extend
    `records_across_modules`).
  - Update the renamed `class P has no field` messages.
- Lower (`lower_test.lua`, `records`): `p.m(f(1))` lowers to a direct call that
  evaluates `p` before `f(1)`.
- Program test `tests/programs/methods.wlo`/`.out`:
  - An ordinary class whose methods read and assign fields through `self`.
  - A method that calls another method and a recursive method.
  - Keyword arguments and defaults.
  - A method on a constructed value, as in `Counter().add()`.
  - A method name that is a Lua keyword, such as `end`.
  - A method on an exception class, called inside an `except` clause.
  - A local variable named like the class still calling methods.
- Program test `tests/programs/method_traceback.wlo`/`.err`: an exception
  raised inside a method shows `in Counter.add` in the traceback.
- Example `examples/shapes.wlo`, run from `cli_test.lua` in the style of
  `number_example`.

## Implementation plan

1. `compiler/parser.lua`:
   - Give `parse_function` a `method` flag that parses the `self` first
     parameter.
   - Rewrite the body loop of `parse_record` to accept fields followed by
     `def` methods into `methods`, with the messages above.
   - Change `"a record name"` to `"a class name"`.
2. `compiler/bind.lua`:
   - Rename the native `methods` maps to `native_methods`.
   - In `declare`, report `duplicate class` for `Record` declarations.
   - Update the `lookup` message and the "cannot be used as a value" message.
   - In `M.bind`, for each method:
     - set `fn.class` and `fn.module`;
     - give `self` the class type;
     - check name uniqueness against methods and fields;
     - check parameter uniqueness;
     - resolve parameter and return types;
     - check defaults;
     - call `resolve_function` alongside module functions.
3. `compiler/check.lua`:
   - Use `native_methods` in `method_signature`.
   - In `MethodCall`, resolve declared-class methods from `Record.methods`, bind
     the arguments to the parameters after `self` with noun `"parameter"`, check
     each argument against its parameter type, set `node.method`, and take the
     method's `return_type`.
   - Rename the `field_type` message.
   - Name methods `method 'C.m'` in the missing-return message.
   - In `M.check`, check every method.
4. `compiler/lower.lua`:
   - In `MethodCall`, when `node.method` is set, lower the receiver and then the
     arguments, and return
     `{ kind = "Call", target = node.method, args = { receiver, ... } }`.
   - Pass `fn.class` through `lower_function`'s result.
   - In `M.lower`, lower each class's methods after the module's functions.
5. `compiler/emit.lua`:
   - Add `class_table(record)`.
   - In `function_name`, name methods `class_table(fn.class) .. "." ..
     M.mangle(fn.name)`.
   - Declare `local __wlo_class_<name> = {}` for each class that has methods,
     next to the module tables.
   - Exclude methods from the entry-module local list and from the
     entry-module export lines.
   - Label method frames `Class.method`.
6. Update and add the tests listed above. Add `examples/shapes.wlo`, with an
   ordinary class with methods and an exception class with a method, and its
   `cli_test.lua` case.
7. Check off the milestone tasks in `agents/todo.md`.

## Documentation updates

- `docs/spec.md` already specifies methods in the working tree. No further
  documentation changes.
