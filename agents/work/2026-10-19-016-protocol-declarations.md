# Protocol declarations and satisfaction

## Plan

`agents/plans/2026-10-19-016-protocol-declarations.md`

## Summary

`protocol P:` declares a protocol of method signatures with no bodies. A
protocol may be generic and may refer to itself. Classes, native types, and
other protocols are assignable to a protocol when their methods are compatible
after substitution, and generic calls infer type arguments through protocol
parameters. Protocols cannot be called, used as values, or used in
`isinstance`, and they have no fields. A method call on a protocol value reports
an interim error until the protocol values task. The spec now describes
built-in standard protocols and `(A, B) -> R` callable types, and the todo has a
task for the callable syntax. The plan's goal is met.

## Decisions

- `assignable` tries protocol satisfaction only for record and protocol
  sources, so scalars and collections fail without any method lookups.
- The `protocols.wlo` program test covers a self-referential method with a
  narrower result (`Rect.scaled -> Rect` serves `Shape.scaled -> Shape`) and an
  extra defaulted keyword-only parameter.

## Checks run

- `make test`: 318 passed, 0 failed.

## Manual verification

1. A program passes protocol values through a list, a parameter, an optional,
   a native `io.File`, and generic inference.

   ```sh
   ./willow run tests/programs/protocols.wlo
   ```

   This printed `2`, `True`, and `2.5`.

## Follow-up work

- Protocol values: run-time dispatch for method calls, which replaces the
  interim error in `check.lua`'s `MethodCall`.
- The VS Code grammar in `editors/vscode` does not highlight `protocol`. It
  also does not highlight `enum`, `lambda`, or `nonlocal`.
