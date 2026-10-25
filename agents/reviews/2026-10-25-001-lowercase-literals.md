# Lowercase literals review

## Scope and coverage

Reviewed all 133 staged files for the completed lowercase `true`, `false`, and
`none` todo item against `docs/spec.md` and the requested transition scope.
Traced keyword recognition, parsing and type normalization, binding, checking,
emission, runtime string conversion, and their callers. Inspected the compiler
tests, new conformance program, expected output and diagnostic changes, and todo
update.

Capitalized spellings remain accepted intentionally. Migrating existing sources,
examples, documentation, editor support, and the frozen stage 1 compiler is out
of scope.

Coverage limits:

- Used the existing macOS build for focused execution checks. The user reports
  that `make bootstrap-test` passed on macOS and Linux in non-root Docker; those
  full runs were not repeated during this review.

## Summary

No findings.

## Checks run

- Inspected the staged diff and relevant callers. Expected output and diagnostic
  changes are lowercase substitutions; the retained literal string `"None"` in
  `tests/programs/processes.out` matches its source helper's explicit return.
- Ran a temporary program mixing both spellings across optional parameters and
  results, keyword and field defaults, explicit generic arguments, callable
  types, generators, async returns, identity tests, print, str, and f-strings.
  Its output matched the expected lowercase values.
- Checked diagnostics for an empty return from an int function, a none argument
  passed to an int parameter, an invalid main result, and an invalid is operand.
  All reported the expected lowercase type or literal spelling.
- Checked that true cannot be assigned to and false and none cannot be used as
  declaration names. All were rejected. The true assignment reports
  `cannot assign to this expression`.
- Ran `build/runner build/willow tests/programs/lowercase_literals.wlo`:
  1 passed, 0 failed.

## Verdict

No confirmed defects within the requested scope. No implementation changes were
made, and this review remains unstaged, following the repository's review
instructions.
