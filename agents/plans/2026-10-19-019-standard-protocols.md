# Standard protocols and protocol bounds

## Goal

Complete the last task of the structural protocols milestone (spec §2 reserved
words, §3 Type parameters, Standard protocols):

- `Iterable[T]`, `Iterator[T]`, `ContextManager[T]`, and `Generator[T]` are
  built-in generic protocols with the contracts in the spec's table. Their
  names are reserved like `list`: they work in annotations and type arguments
  everywhere, without imports, and cannot name anything else.
- A type parameter's bound may be a protocol, as in `T: Shape`. A value of `T`
  supports the protocol's method calls, which dispatch like protocol values.
- `examples/stdlib/shapes.wlo` declares a `Shape` protocol served by `Rect` and
  a new `Circle` class.

User classes can satisfy the standard protocols and be called through them
explicitly. Built-in values satisfying them, `iter`/`next`, `for` over
iterables, generators, and `with` belong to later milestones.

## Related code

- `compiler/lexer.lua`: the `keywords` set, which holds the reserved type
  names.
- `compiler/parser.lua`: `type_names`, `parse_member`, and the `isinstance`
  class name, which accepts `type_names`.
- `compiler/stdlib.lua`: the built-in exception declarations, built as Lua
  tables; the new protocol declarations follow that pattern.
- `compiler/bind.lua`: `resolve_named` (finds declarations and built-in
  exceptions), `enter_type_params` (bound kinds), and the `isinstance` branch.
- `compiler/check.lua`: `MethodCall` replaces a bounded type parameter with its
  bound before dispatching, so a protocol bound reaches the protocol branch.
- `compiler/types.lua`: `unsatisfied` and `assignable` already treat a bound
  through `assignable`, which accepts protocols.
- `examples/stdlib/shapes.wlo`.

## Decisions

- The four protocols are declarations built in `stdlib.lua` (`M.protocols`),
  with the fields bind gives a parsed generic protocol: `kind = "Protocol"`,
  `name`, `type_name`, `type_params`, `typevars`, `self_type`, and `methods`
  whose `params` start with `self` and whose types are already resolved. Each
  has its own type parameter `T`. Their method signatures follow the spec's
  table; `exit` takes `error: Exception | None`, and `Generator.iter` returns
  `Iterator[T]`.
- The lexer reserves the four names as keywords, and the parser adds them to
  `type_names`. In `parse_member` they take `[...]` arguments like a named type.
  `resolve_named` falls back to `stdlib.protocols` after the built-in
  exceptions, so the generic-protocol path in `resolve_type` and `type_text`
  handles them unchanged, including "needs type arguments" and
  "isinstance" errors.
- `enter_type_params` accepts a protocol bound, and the error becomes "a type
  parameter's bound must be a class, native type, or protocol".
- No lowering or emission change: a call on a bounded value or on a standard
  protocol value already lowers to protocol dispatch, and the converters treat
  built-in protocol declarations like any other.
- `shapes.wlo` takes `WIDTHxHEIGHT` or `rRADIUS` arguments, parses each into a
  `Shape`, and prints each area and doubled area and the total, as before.

## Test plan

- `tests/unit/parser_test.lua`: `def f(x: Iterable[int], y: ContextManager[str]) -> Generator[Iterator[int]]`
  parses; `Iterator = 1` is rejected as a reserved word.
- `tests/unit/bind_test.lua`: `isinstance(x, Iterable)` reports "protocol
  'Iterable' cannot be used in isinstance"; `x: Iterable` reports "type
  'Iterable' needs type arguments"; `def f[T: int]` reports the new bound
  message.
- `tests/unit/check_test.lua`:
  - a class with `iter(self) -> Counter` and `next(self) -> int` is assignable
    to `Iterator[int]` and `Iterable[int]`, but not `Iterator[str]`;
  - a class with `enter` and `exit(self, error: Exception | None) -> None`
    satisfies `ContextManager[str]`; naming the parameter `e` does not;
  - `Generator[int]` is assignable to `Iterator[int]` and
    `ContextManager[Generator[int]]`, and `Iterator[int]` is not assignable to
    `Generator[int]`;
  - with `def total[T: Shape](xs: list[T]) -> float`, `x.area()` type-checks in
    the body, `total([1])` reports "type argument int does not satisfy the
    bound Shape of 'T'", and `x.width` reports the protocol's missing field.
- `tests/programs/standard_protocols.wlo` and `.out`: a counter class used as
  `Iterator[int]` and `Iterable[int]`, advanced with explicit `next()` and
  `iter()` calls; a manager class used as `ContextManager[str]` with explicit
  `enter()` and `exit(None)`; a generic `total[T: Shape]` summing areas of a
  `list[Rect]` and a `list[Circle]` through the bound.
- `examples/stdlib/shapes.wlo`: `willow run examples/stdlib/shapes.wlo 3x4 r1`
  prints both shapes and the total; a bad argument still reports through
  `ShapeError`.
- `make test` passes.

## Implementation plan

1. `compiler/stdlib.lua`: build the four protocol declarations.
2. `compiler/lexer.lua` and `compiler/parser.lua`: reserve the names and parse
   them as types.
3. `compiler/bind.lua`: resolve them in `resolve_named`; accept protocol
   bounds.
4. Tests above, then `shapes.wlo`.
5. `agents/todo.md`: check off the task and the milestone.
