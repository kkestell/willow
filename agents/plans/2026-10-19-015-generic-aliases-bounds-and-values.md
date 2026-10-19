# Generic aliases, bounds, and generic function values

## Goal

Finish the generics milestone in `agents/todo.md` (spec §3 Type parameters and
Type aliases, §5 Function values).

- Aliases take type parameters, as in `type Pair[K, V] = tuple[K, V]`. They
  may recurse through `list` and `dict`.
- A type parameter may have one upper bound that is a class or a native type,
  as in `T: io.File`. Values of `T` then allow the bound's fields and methods,
  and convert to the bound.
- A generic function becomes a value when explicit type arguments
  (`first[int]`) or an expected callable type fix its specialization.
- Add Rosetta Code "Parametric polymorphism".

## Related code

- `compiler/parser.lua`:
  - `parse_type_params` reports "type parameter bounds are not supported";
  - the `type` alias statement;
  - `parse_specialized_call` only handles `[types](`.
- `compiler/bind.lua`:
  - `resolve_alias`, `resolve_type` (Alias branch), `enter_type_params`;
  - `declared_value` ("generic function cannot be used as a value");
  - `SpecializedCall` resolution and its index fallback.
- `compiler/types.lua`: `typevar`, `assignable`.
- `compiler/check.lua`:
  - `field_type`, `MethodCall`, `class_method`, `method_signature`;
  - `specialize`, `infer_call`, `collect`;
  - `FunctionValue`.
- `compiler/lower.lua` `MethodCall` (`prefix(node.object.type)`) and `FunctionValue`.

## Decisions

- Generic aliases:
  - `type Name[T, ...] = ...` stores `type_params`.
  - Using a generic alias calls `apply_alias(decl, args)`. This resolves the
    alias's body with a type scope mapping each parameter name to its argument
    type, and caches the result in `decl.applications`, keyed by the argument
    type names.
  - A recursive use with the same arguments inside `list` or `dict` is lazy,
    and finds the cached result when forced, so recursion ends. A recursive
    use not inside `list` or `dict` finds the application still resolving
    and reports "alias 'X' expands to itself".
  - `resolve_alias` validates a generic alias's body once by applying it to
    its own typevars, so errors such as `T | int` are reported where the alias
    is declared.
  - A generic alias used without arguments reports "type 'Pair' needs type
    arguments", and the argument count is checked.
  - In a union, a member naming a type parameter adds only the members not
    already present, so `T | None` with `T = int | None` is `int | None`.
- Bounds:
  - `T: Bound` parses the bound as a type node, and `enter_type_params`
    resolves it into `typevar.bound`.
  - A bound that is not a class or native type reports "a type parameter's
    bound must be a class or native type".
  - `types.assignable` accepts a bounded typevar wherever its bound is
    accepted.
  - In check, field reads and writes and method calls on a bounded typevar use
    the bound. A `MethodCall` on one records `node.receiver = bound`, and
    lowering's helper prefix uses `node.receiver` when present.
  - Every type argument, whether explicit, inferred, or in a generic class
    annotation, must be assignable to its parameter's bound. Otherwise report
    "type argument int does not satisfy the bound io.File of 'T'".
- Generic function values:
  - `parse_specialized_call` also produces a `Specialized` node with `callee`
    and `type_args` when `[types]` parses but no `(` follows.
  - Bind turns it into a `FunctionValue` with `type_args` when the callee names
    a generic function. Otherwise it becomes an `Index`, by the same fallback
    as calls.
  - A bare generic function name is also a `FunctionValue`, and check decides
    its specialization:
    - With `type_args`, its type is `typing.Callable[[required positional
      parameter types], result]`, substituted. A function with required
      keyword-only parameters reports that it cannot become a callable.
    - Without them, the expected type's callable member fixes the type
      arguments: `collect` matches parameters and result against it. The
      value's type is that callable, provided the substituted function serves
      it.
    - With neither, report "generic function 'f' needs type arguments or an
      expected callable type".
  - Lowering converts a generic `FunctionValue` from its declaration's
    function type to its callable type, so the existing adapter supplies
    defaults.
  - Generic methods and nested generic `def`s as values stay rejected.
- Rosetta Code: "Parametric polymorphism" defines `Tree[T]` with a
  `map[U]` method that builds a `Tree[U]`, and prints a tree of ints mapped
  to strings.

## Test plan

- `tests/unit/parser_test.lua`:
  - `type Pair[K, V] = tuple[K, V]` stores `type_params`;
  - `def f[T: io.File]` stores the bound;
  - `first[int]` parses as `Specialized`.
- `tests/unit/bind_test.lua`:
  - `Pair[int, str]` resolves to `tuple[int, str]`;
  - a recursive `type Nested[T] = list[Nested[T]]` resolves;
  - `type Bad[T] = Bad[T]` reports "expands to itself";
  - `Pair` without arguments is rejected;
  - a bound of `int` is rejected;
  - `xs[i]` stays an index.
- `tests/unit/check_test.lua`:
  - an explicit argument violating a bound reports the bound error;
  - a field missing from the bound is rejected;
  - `f = identity` with no expected type reports the needs-arguments error;
  - `g: typing.Callable[[int], str] = identity` reports a type error.
- `tests/programs/generics.wlo` and `.out`:
  - a generic alias used for a parameter;
  - a recursive generic alias holding nested lists;
  - a bounded type parameter reading a field and calling a method of its class
    bound;
  - a bound of `io.File` calling `write_text`;
  - `first[int]` stored and called;
  - `identity` passed where `typing.Callable[[str], str]` is expected.
- `examples/rosettacode/parametric_polymorphism.wlo` and `.out`.

## Implementation plan

- `compiler/parser.lua`: alias type parameters; bounds; `Specialized` nodes.
- `compiler/types.lua`: bounded typevars in `assignable`.
- `compiler/bind.lua`:
  - `apply_alias` and alias validation;
  - the union rule for substituted members;
  - bound resolution;
  - `Specialized` resolution;
  - generic `FunctionValue`s.
- `compiler/check.lua`:
  - bound-aware field and method access;
  - bound checks for type arguments;
  - generic `FunctionValue`s.
- `compiler/lower.lua`: `node.receiver` for helper prefixes; generic
  `FunctionValue` conversion.
- Tests and example listed above; `agents/todo.md`: check off the task and the
  milestone.
