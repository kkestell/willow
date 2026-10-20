# Protocol values

## Plan

`agents/plans/2026-10-19-018-protocol-values.md`

## Summary

Method calls on protocol values dispatch on the value's run-time type through
per-protocol tables of generated converters. Converters apply implementation
defaults for omitted arguments and extra optional parameters, reorder
keyword-only parameters, and box or unbox floats at positions whose declared
types are concrete. Protocol satisfaction rejects float representation changes
at type-parameter positions and between protocols, as the plan describes. The
plan's goal is met, with that restriction as the one departure from the spec.

## Departures from the plan

- A missing argument in a protocol call reports the existing arity message
  ("'read' expects 1 argument, received 0") rather than "missing argument",
  because `bind_args` checks arity first. The test expects that message.

## Decisions

- Every protocol call passes its site index as the last argument, including
  to class methods, which ignore it. This keeps one calling convention for
  class and native entries, so a native helper can serve as its own entry.

## Checks run

- `make test`: 319 passed, 0 failed.

## Manual verification

1. A protocol and class in an imported module, with a class in the entry
   module, dispatch across modules, and the implementations' defaults apply.

   ```sh
   # geo.wlo: protocol Shape with area(self, scale: float = 1.0) -> float,
   # class Square whose area defaults scale to 2.0, and total(list[Shape]).
   # main.wlo: class Dot whose area defaults scale to 0.5, summed with Square(3.0).
   ./willow run main.wlo
   ```

   Printed `18.5` and `4.0`.

2. The generated Lua for `tests/programs/protocols.wlo` uses the method or
   native helper itself where nothing converts, and short converter functions
   otherwise.

   ```sh
   ./willow compile tests/programs/protocols.wlo -o /tmp/p.lua
   ```

## Follow-up work

- The spec allows a `float` result to serve an `int | float` position reached
  through a type parameter (for example, a class whose `get` returns `float` as
  `Source[int | float]`), and protocol-to-protocol assignments that change a
  float's representation. These are rejected, because a protocol value does not
  record the specialization that decides how its floats are stored. Supporting
  them needs either wrapping protocol values or recording representations at
  run time.
