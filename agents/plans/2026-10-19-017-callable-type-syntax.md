# Callable type syntax

## Goal

Replace `typing.Callable[[A, B, ...], R]` with the annotation form
`(A, B, ...) -> R` that `docs/spec.md` §3 already specifies. A callable's return
type extends as far as possible, so `(int) -> str | None` returns `str | None`,
and parentheses around any other type group it, as in `((int) -> str) | None`.
Diagnostics name callable types in the same syntax. The `typing` module is
removed, so `import typing` reports the existing unknown-module error. Callable
semantics (assignability, adaptation, calls, lambdas) are unchanged.

## Related code

- `compiler/parser.lua` — `parse_member` and `parse_type` parse annotations.
  `parse_member` reads `TypeList` arguments only for `typing.Callable`.
  `parse_specialized` parses `[types]` after a name speculatively and falls back
  to an index, so grouped types there stay harmless.
- `compiler/bind.lua` — `type_text` (lazy type names), `resolve_type`,
  `resolve_named`, `CANNOT_CALL`, and the `isinstance` check each have a
  `Callable` declaration branch or a `TypeList` check.
- `compiler/types.lua` — `M.callable` builds the display name; `M.union` joins
  member names.
- `compiler/stdlib.lua` — the `typing` module provides `Callable`.
- Tests and examples that import `typing`: `tests/unit/parser_test.lua`,
  `tests/unit/bind_test.lua`, `tests/unit/check_test.lua`,
  `tests/programs/{bound_methods,callables,closures,lambdas,generics,generic_classes}.wlo`,
  `examples/rosettacode/{closures_value_capture,parametric_polymorphism,higher_order_functions}.wlo`.

## Decisions

- New AST node `CallableType` with `params` (list of type nodes) and `result`
  (a type node), spanning from the `(` token. Grouping returns the inner type
  node itself; no group node exists.
- Parsing in `parse_member` on `(`:
  - `()` must be followed by `->`: a callable with no parameters.
  - After the first type, a `,` means a parameter list (via `parse_list`,
    trailing comma allowed), which must be followed by `->`.
  - Otherwise `)` closes; with `->` following it is a one-parameter callable,
    and without it the parentheses group the type.
  - The result is parsed with `parse_type`, so it absorbs any following `|`
    members. A callable written as a later union member without parentheses,
    as in `str | (int) -> int | None`, therefore returns `int | None`; this
    follows from the spec's rule and needs no special handling.
- Display names: `M.callable` names a callable `(A, B) -> R`. `M.union` wraps
  callable member names in parentheses, giving `((int) -> str) | None`.
  `type_text` produces the same text for `CallableType` nodes and wraps
  `CallableType` members of a `UnionType` the same way. No other position
  needs parentheses: parameters are comma-separated inside parentheses, and a
  result extends to the end.
- Remove the `Callable` declaration kind everywhere (bind's `resolve_named`
  kinds, `type_text`, `resolve_type`, `CANNOT_CALL`, the `isinstance` branch)
  and the `TypeList` node with it. Named-type arguments become plain
  `parse_list("]", parse_type)`; the "expected a type" `TypeList` check in
  generic arguments goes away because the parser now rejects `[` there.
- Callables cannot reach `isinstance`: its class argument is a name, not a
  type annotation, so no new diagnostic is needed there.

## Test plan

- `tests/unit/parser_test.lua`: replace `callable_annotations` with the new
  syntax and teach `show` to print `CallableType` (as `(A, B) -> R`, with
  parentheses around a callable result shown explicitly so precedence is
  visible). Cases:
  - `def f(g: (int, str) -> bool, h: () -> int) -> None` round-trips.
  - `(int) -> str | None` parses as a callable whose result is a union.
  - `((int) -> str) | None` parses as a union whose first member is a callable.
  - `(int)` alone parses as `int`; `(int) -> (str) -> bool` nests to the right;
    `((int) -> int) -> int` takes a callable parameter.
  - `(int, str)` without `->` reports `expected '->'`.
- `tests/unit/bind_test.lua`: port the callable cases to the new syntax and
  expect names like `(int, str | None) -> bool` and `(P) -> None`. Drop the
  `typing.Callable` arity and `isinstance` errors (no longer expressible).
  Keep the union conflict case as `((int) -> int) | ((str) -> int)` with its
  existing message. Add: `import typing` reports the unknown-module diagnostic.
- `tests/unit/check_test.lua`: port each case; expected messages change only in
  the type names, e.g. `expected (int) -> int, received function k` and
  `cannot print a value of type (int) -> int`. Add one diagnostic naming an
  optional callable, e.g. assigning `1` to `((int) -> int) | None`, to show the
  parenthesized union name.
- Program tests and Rosetta examples: rewrite the annotations; their expected
  output files stay unchanged, which shows the runtime behavior is preserved.
  `callables.wlo` already exercises a callable parameter of a callable and an
  optional callable (`call_optional`), now written `((int) -> int) -> int` and
  `((int) -> int) | None`.
- `make test` passes.

## Implementation plan

1. `compiler/types.lua`: new callable name; parenthesize callable members in
   `M.union`.
2. `compiler/parser.lua`: `CallableType` and grouping in `parse_member`; drop
   `TypeList` from named-type arguments; update the comments describing type
   nodes.
3. `compiler/bind.lua`: handle `CallableType` in `type_text` and
   `resolve_type` (resolve params and result with `resolve_type`, as the old
   branch did); remove the `Callable` kind and `TypeList` checks.
4. `compiler/stdlib.lua`: delete the `typing` module.
5. Update unit tests, program tests, and the three Rosetta examples; run
   `make test`.
6. `agents/todo.md`: check off the callable type syntax item.

## Documentation updates

- None. `docs/spec.md` already specifies the new syntax and never documents
  `typing`.
