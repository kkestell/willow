# Application tests and editor basics review

## Scope and coverage

Reviewed the staged implementation of `agents/plans/2026-10-16-002-application-tests-and-editor-basics.md` against the plan and `docs/spec.md` §1, §8, §9, §10, and §12: `assert` parsing in `compiler/parser.lua`; `AssertionError`, `Assert` resolution, and test-mode `entry.tests` in `compiler/bind.lua`; `Assert` checking and narrowing in `compiler/check.lua`; `Assert` lowering in `compiler/lower.lua`; the test chunk ending in `compiler/emit.lua`; `__wlo_assert_fail` in `runtime/core.lua`; `compiler/runner.lua` and the `test` command in `compiler/cli.lua`; the `WILLOW` export in `willow`; `editors/vscode/`; `examples/cart/`; `tests/suites/failing/`; the unit and program tests; and the README, spec, and todo updates. The editor extension was inspected and its JSON validated but not loaded in VS Code.

## Fixed

- **Unwrapped spec paragraph** (`docs/spec.md:666`): The control-transfer paragraph had one line past the 80-column wrap after the `assert` sentence was added. Rewrapped it.

## Findings

No open findings.

## Checks run

- `make test`: 221 passed.
- `assert i == 0 or t("cond"), m()` in a loop evaluates the short-circuit condition once and the message only when the condition is false.
- `except Exception` catches an `AssertionError`.
- `willow test sub/`, `willow test ./`, and `willow test missing.wlo` report `sub/test_x.wlo`, `./test_x.wlo`, and `error: missing.wlo: No such file or directory` with exit 1.
- A test file in an import cycle (`test_a` imports `b`, which imports `test_a`) runs its test.
- An explicit file with `main` and no `test_*` functions reports `error: no tests found in test_m.wlo` with exit 1.
- The three `editors/vscode` JSON files parse; grammar built-ins and exception names match `compiler/bind.lua`.

## Verdict

The implementation matches the plan and the spec. One documentation wrap fixed; no open findings.
