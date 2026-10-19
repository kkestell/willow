# Generic functions with explicit specialization

## Goal

Start the generics milestone in `agents/todo.md` (spec §3 Type parameters, §4
Unions).

- File-level and nested functions may declare type parameters, as in
  `def first[T](items: list[T]) -> T`. A parameter may not hide another type
  parameter in scope.
- Inside the body, a value of a type parameter can only be stored, passed, and
  returned. The body is checked once for every permitted type argument.
- A type parameter may appear in a union only alongside `None`, and
  substitution flattens the union.
- Calls specialize explicitly: `first[int](numbers)`.
- The body is compiled once, and values of a type parameter are never
  converted between float representations.
- Inference, generic classes and aliases, bounds, and generic function values
  are later tasks.

## Related code

- `compiler/parser.lua` `parse_function`, `parse_postfix` (`[` makes `Index`).
- `compiler/bind.lua` `resolve_type`, `lazy`/`force_pending`, `resolve_named`,
  `resolve_signature`, `resolve_function` (`Call`, `Name`, `IsInstance`,
  `FunctionDef`), and `collect_symbols`.
- `compiler/types.lua` `same`, `key`, `union`, `conflict`.
- `compiler/check.lua` `Call`, `CallValue`, `bind_args`.

## Decisions

- Syntax:
  - `def name[T, U](...)` stores `type_params`, a list of `{ name, span }`. A
    `:` after a parameter reports "type parameter bounds are not supported".
  - In `parse_postfix`, a `[` after a `Name` is first tried as type arguments:
    the parser saves the position and parses `parse_list("]", parse_type)`
    under `pcall`.
  - If that succeeds and a `(` follows, the result is a `SpecializedCall`
    with `callee`, `type_args`, and `args`. Otherwise the parser restores the
    position and parses an index as before.
  - So `xs[0](x)` stays an index call. `xs[i](x)` parses as a
    `SpecializedCall` that bind turns back into an index call.
- Type parameters in scope:
  - `types.typevar(name)` returns `{ kind = "typevar", name }`, compared by
    identity like records. It is not comparable or printable and has no
    operations, so `==`, `print`, arithmetic, fields, and methods are already
    rejected.
  - Bind keeps a module-level `type_scope` (name to typevar). Resolving a
    generic function's signature and body extends a copy of it with the
    function's parameters, reporting "type parameter 'T' hides another type
    parameter" for a repeat. `resolve_type` looks there before declarations.
  - A `lazy` type records the scope it was made in, and `force_pending`
    restores that scope while resolving it, so `list[T]` resolves after the
    function's scope ends.
  - A union with a typevar member and any member other than `None` reports
    "a type parameter can be in a union only with None".
  - `isinstance(x, T)` reports "type parameter 'T' cannot be used in
    isinstance".
- Substitution: `types.substitute(t, map)` rebuilds lists, dicts, tuples,
  callables, and unions with typevars replaced. Unions flatten and drop members
  that `same` already holds, so `T | None` with `T = int | None` is
  `int | None`.
- Calls:
  - A `SpecializedCall` whose callee names a generic file-level function
    becomes a `Call` with `type_args` (resolved types).
  - A local bound by a generic nested `def` (bind marks `symbol.def` when a
    `FunctionDef` binds it) becomes a `CallValue` with `type_args`.
  - Any other callee with one simple type argument (a name or dotted name)
    becomes `CallValue(Index(callee, Name or Field))`. Otherwise it reports
    "'f' is not generic".
  - Check matches the count to the type parameters, reporting "'first'
    expects 1 type argument, received 2". It binds arguments with parameter
    types substituted and substitutes the return type.
  - Calling a generic without type arguments reports "'first' needs type
    arguments", and naming it as a value reports "generic function 'first'
    cannot be used as a value". Inference and generic values are later tasks.
- Lowering and runtime are unchanged: arguments convert to the substituted
  parameter types at the call, and the body never converts values of a type
  parameter, so each value keeps the caller's representation.

## Test plan

- `tests/unit/parser_test.lua`:
  - `def f[T, U](x: T) -> U` stores `type_params`;
  - `first[int](xs)` and `first[list[int]](xs)` parse as `SpecializedCall`;
  - `xs[0](1)` stays an index call;
  - `def f[T: int]` is rejected.
- `tests/unit/bind_test.lua`:
  - a parameter `list[T]` resolves to a list of the typevar;
  - a nested `def g[T]` inside `def f[T]` reports the hiding error;
  - `T | int` is rejected and `T | None` is accepted;
  - `isinstance(x, T)` is rejected;
  - `xs[i](1)` becomes an index call;
  - `first` as a value is rejected.
- `tests/unit/check_test.lua`:
  - in a body, `x + x`, `print(x)`, `x == x`, and `x.n` on a `T` are
    rejected;
  - `first[int](["a"])` reports "expected list[int], received list[str]";
  - `first(xs)` needs type arguments;
  - a type argument count mismatch is rejected.
- `tests/programs/generics.wlo` and `.out`:
  - `first[int]` and `first[str]`;
  - a `T | None` parameter defaulting to `None` and narrowed with
    `is not None`;
  - `repeat[T](x: T, n: int) -> list[T]`;
  - a nested generic function called with explicit arguments;
  - `T = int | float` holding `2.5` passes through and still tests as a float;
  - `T = int | None` substituted into `T | None`.

## Implementation plan

- `compiler/types.lua`: `typevar`, `substitute`; typevar handling in `same` and `key`.
- `compiler/parser.lua`: type parameter lists; `SpecializedCall`.
- `compiler/bind.lua`: `type_scope`, lazy scope capture, the union and
  `isinstance` rules, `SpecializedCall` resolution, `symbol.def`, and the
  value and no-argument errors.
- `compiler/check.lua`: specialized `Call` and `CallValue`.
- Tests listed above; `agents/todo.md`: check off the task.
