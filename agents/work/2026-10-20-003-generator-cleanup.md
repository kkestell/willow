# Generator cleanup

## Plan

`agents/plans/2026-10-20-003-generator-cleanup.md`

## Summary

Tests now cover generator closing: `finally` clauses run inner to outer with no
`except` handler, repeated and post-exhaustion closes do nothing, cleanup
errors propagate and leave the generator closed, `enter` and `exit` work, and
`Iterator`/`Iterable` annotations hide the other methods. The Rosetta Code
"Generator/Exponential" example prints the expected values. No compiler or
runtime change was needed. The plan's goal is met, and the generators
milestone is complete.

## Checks run

- `make test`: 330 passed, 0 failed.
- `luajit tests/run.lua examples/rosettacode/generator_exponential.wlo`:
  1 passed.
