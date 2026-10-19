# `nonlocal` and lambdas

## Plan

`agents/plans/2026-10-19-011-nonlocal-and-lambdas.md`

## Summary

`nonlocal` lets nested functions rebind enclosing variables under the spec's
rules, and lambdas take parameter types from an expected callable and infer
their result otherwise. Both Rosetta Code examples are added. The plan's goal
is met.

## Decisions

- A repeated `nonlocal` of the same name is accepted silently.
- The parser test that expected "'lambda' is not supported" now checks
  `yield`, which is still unsupported.

## Checks run

- `make test` — 303 passed, 0 failed.
- Every `examples/rosettacode/*.wlo` matches its `.out`.

## Manual verification

1. `tests/programs/lambdas.out` was read against the program: two counters
   count independently (`1 2 1`), `total` reads the rebinding (`7`), and the
   loop lambdas all return the loop's last value (`2`).

   ```sh
   ./willow run tests/programs/lambdas.wlo
   for f in examples/rosettacode/*.wlo; do ./willow run "$f" 2>&1 | diff -q - "${f%.wlo}.out" >/dev/null || echo "DIFF $f"; done
   ```
