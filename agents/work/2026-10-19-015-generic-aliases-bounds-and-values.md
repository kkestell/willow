# Generic aliases, bounds, and generic function values

## Plan

`agents/plans/2026-10-19-015-generic-aliases-bounds-and-values.md`

## Summary

Aliases take type parameters and may recurse through `list` and `dict`. Type
parameters take one class or native bound whose fields and methods their values
use, and type arguments must satisfy it. Generic functions become values
through explicit type arguments or an expected callable type. Rosetta Code
"Parametric polymorphism" is added. The plan's goal is met.

## Departures from the plan

- `apply_alias` caches applications by the identity of their argument types
  rather than their names, since two type parameters named `T` would share a
  name; a use that expands without end (more than 100 applications) reports
  "alias 'X' expands without end".
- A union dedupes repeated members whenever one of its members names a
  substituted type argument, so `type Maybe[T] = T | None` with
  `T = int | None` is `int | None`.
- `xs[i] = v` and `xs[i]: T = v` turn a `Specialized` target back into an
  index in the parser, through a shared `ast.index_from_type`, which also
  reads subscripted names such as `values[numeral[i]]` back as index
  expressions; `roman_numerals_decode.wlo` exposed that case.
- Generic aliases resolve their bounds through `enter_type_params`, which
  moved ahead of `apply_alias`.

## Checks run

- `make test` — 313 passed, 0 failed.
- Every `examples/rosettacode/*.wlo` matches its `.out`, and every
  `examples/stdlib/*.wlo` passes `willow check`.

## Manual verification

1. `tests/programs/generics.out` and
   `examples/rosettacode/parametric_polymorphism.out` were read against their
   programs.

   ```sh
   ./willow run examples/rosettacode/parametric_polymorphism.wlo
   ```

   `((. 1 .) 4 (. 9 .))`.
