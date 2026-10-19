# Generic classes and methods

## Goal

Continue the generics milestone in `agents/todo.md` (spec §3 Type parameters,
§4 Unions).

- Classes and methods may declare type parameters, as in `class Box[T]` and
  `def map[U](self, ...)`.
- Annotations name a generic class with all of its type arguments, as in
  `Box[int]`.
- Constructors infer their type arguments, or take them explicitly as in
  `Box[str]("hello")`.
- Field reads and writes and method calls use types substituted for the
  specialization.
- Method bodies see both class and method type parameters.
- Specializations are invariant, and a union holds at most one
  specialization of a class.
- `isinstance(x, Box)` tests by class name.
- Exception classes cannot be generic.
- All of this works across modules.

## Related code

- `compiler/parser.lua` `parse_record`, `parse_function` (type parameter lists).
- `compiler/bind.lua` `declare`, `resolve_type`, `type_text`, `resolve_named`, `enter_type_params`, `resolve_signature`, `resolve_function`, the record loop in `M.bind`, `is_generic`, and `SpecializedCall` resolution (including module-qualified callees).
- `compiler/types.lua` `record`, `same`, `key`, `conflict`, `has_typevar`, `substitute`.
- `compiler/check.lua` `field_type`, `class_method`, `Call` (constructors), `MethodCall`, `Field` (bound methods), `IsInstance`, `specialize`, `infer_call`.

## Decisions

- Syntax: one `parse_type_params` helper reads `[T, U]` after a function or
  class name. Classes store `type_params` like functions. The bind error for
  generic methods goes away.
- Declarations: `declare` gives a generic class `typevars` (one
  `types.typevar` per parameter) and `self_type = types.generic(decl,
  typevars)`. A non-generic class has `self_type = decl.type`. A generic
  exception class reports "exception classes cannot be generic".
- Types:
  - `types.generic(decl, args)` returns
    `{ kind = "record", record = decl, args, name = "Box[int]" }` and is not
    cached.
  - `same` compares records by declaration and, for specializations, by each
    argument, so specializations are invariant.
  - `has_typevar` and `substitute` walk `args`, and substitution rebuilds
    `types.generic`.
  - `types.record_map(t)` maps a specialization's class typevars to its
    arguments.
  - `conflict` reports "a union can have only one specialization of Box".
- Annotations: `resolve_type` on a generic class requires its arguments,
  reporting "type 'Box' needs type arguments" or "'Box' expects 1 type
  argument, received 2", and builds `types.generic`. `type_text` includes the
  arguments.
- Scopes:
  - Field types resolve with the class's type parameters in scope.
  - Method signatures and bodies enter the class's parameters, then the
    method's, so a method parameter named like a class parameter reports the
    hiding error.
  - A method's `self` has the class's `self_type`.
- Check:
  - `field_type` substitutes `record_map(object)`, which covers reads and
    writes.
  - A `MethodCall` on a specialization substitutes the class map into the
    method's parameters and result. A method with its own type parameters
    infers them through `infer_call`, given the substituted parameters and a
    stand-in `{ typevars, return_type }`.
  - Constructor calls of a generic class use `specialize` for explicit
    arguments and `infer_call` otherwise, with the fields as parameters. Their
    type is `self_type` substituted.
  - `isinstance` matches a union member by its class declaration, so `Box`
    finds `Box[int]`.
- Values: reading a method of a generic class, or a method with its own type
  parameters, as a value reports "methods of generic classes cannot be used
  as values". Bound methods of non-generic classes are unchanged.
- Explicit method specialization (`b.map[int](f)`) is not supported; method
  type parameters are inferred.
- Bind: `is_generic` also accepts generic classes, so `Box[str](...)` and
  `mod.Box[str](...)` become constructor `Call`s with `type_args`.
- Lowering and runtime are unchanged. Arguments and field assignments convert
  to the substituted types, and values of a type parameter keep the caller's
  representation, as in generic functions.

## Test plan

- `tests/unit/parser_test.lua`: `class Box[T]:` stores `type_params`; a method
  with `[U]` parses.
- `tests/unit/bind_test.lua`:
  - `Box` without arguments in an annotation is rejected;
  - the argument count is checked;
  - `class E[T](Exception)` is rejected;
  - a method type parameter named `T` in `class Box[T]` is rejected;
  - `Box[int] | Box[str]` is rejected.
- `tests/unit/check_test.lua`:
  - `b: Box[int | None] = Box[int](1)` is rejected (invariance);
  - `Box[int](1).value = 'a'` is rejected;
  - `x: str = Box(1).get()` is rejected;
  - `f = Box(1).get` is rejected;
  - a method body using `T` arithmetic is rejected.
- `tests/programs/generic_classes.wlo` and `.out`:
  - `Box(1)` and `Box[str]("a")`, with field reads and writes;
  - a method returning `T`;
  - a method `map[U]` inferring `U` from a lambda and returning `Box[U]`;
  - a recursive generic `Node[T]` with an `Node[T] | None` field;
  - `isinstance(x, Box)` on `Box[int] | None`;
  - a `Box[int | float]` keeping `2.5` as a float through a method.
- `tests/modules/qualified/...`: a generic class in `app/models.wlo`
  annotated and constructed as `app.models.Pair[...]` from `main.wlo`.

## Implementation plan

- `compiler/parser.lua`: `parse_type_params` for functions and classes.
- `compiler/types.lua`: `generic`, `record_map`; `same`, `has_typevar`,
  `substitute`, and `conflict`.
- `compiler/bind.lua`: generic class declarations, annotations, and scopes;
  `is_generic` for classes; remove the generic-method error.
- `compiler/check.lua`: substituted fields, methods, and constructors;
  `isinstance` by declaration; the method-value error.
- Tests listed above; `agents/todo.md`: check off the task.
