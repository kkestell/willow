# Keyword-only parameters review

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-19-005-keyword-only-parameters.md`: `*` parsing and default ordering in `parse_function` (`compiler/parser.lua`), keyword-only binding in `bind_args` (`compiler/check.lua`) for functions, declared methods, native methods, constructors, and builtins, the lowering path that consumes `node.order`, and the new tests, against spec §3 Functions and §5 Calls.

Gaps:

- Function values and `Callable` conversion (spec §5) are not implemented yet, so the rule that functions with required keyword-only parameters do not convert to `Callable` was not reviewed.

## Summary

| ID | Severity | Category       | Fix   | Title                                         |
| -- | -------- | -------------- | ----- | --------------------------------------------- |
| F1 | Medium   | Error handling | Fixed | `def f(*)` crashes the parser                 |

## F1. `def f(*)` crashes the parser

Medium · Error handling · Fixed · `compiler/parser.lua:737`

A function whose parameter list holds only a bare `*` leaves `params` empty, so the check for a keyword-only parameter after `*` indexes `nil` and the compiler reports an internal error instead of "'*' must be followed by a keyword-only parameter". Methods are not affected because `self` is always in `params`.

### Evidence

```text
$ ./willow run a.wlo   # def f(*) -> None:
internal compiler error: compiler/parser.lua:737: attempt to index a nil value
```

### Fix

The check now treats an empty parameter list as having no keyword-only parameter, and `tests/unit/parser_test.lua` covers `def f(*)`, which reports `1:7: '*' must be followed by a keyword-only parameter`.

## Checks run

- Reproduced F1 with `./willow run` on `def f(*) -> None:`; after the fix it reports the intended diagnostic.
- `make test`: 286 passed, 0 failed.

## Verdict

The change matches the plan and spec. F1, a parser crash on a bare `*` with no parameters, is fixed and covered by a regression test.
