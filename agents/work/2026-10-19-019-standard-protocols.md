# Standard protocols and protocol bounds

## Plan

`agents/plans/2026-10-19-019-standard-protocols.md`

## Summary

`Iterable`, `Iterator`, `ContextManager`, and `Generator` are reserved,
built-in generic protocols declared in `stdlib.lua`. User classes satisfy them
and are called through them. Type parameters accept protocol bounds, and calls
on bounded values dispatch through the protocol. `shapes.wlo` sums rectangles
and circles through a `Shape` protocol. The plan's goal is met, and the
structural protocols milestone is complete.

## Checks run

- `make test`: 320 passed, 0 failed.

## Manual verification

1. `shapes.wlo` prints the same rectangle lines as before, adds circles, and
   still reports bad arguments.

   ```sh
   ./willow run examples/stdlib/shapes.wlo 3x4 2x2.5 r1
   ./willow run examples/stdlib/shapes.wlo 3x4 rz
   ```

   The first printed `12.0`, `5.0`, and `3.141592653589793` areas and
   `total 20.141592653589793`. The second printed `rz: not a number` to
   stderr and exited with status 2.
