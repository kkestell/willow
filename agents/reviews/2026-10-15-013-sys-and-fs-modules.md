# `sys` and `fs` modules

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-15-013-sys-and-fs-modules.md`
against `docs/spec.md` §1, §12, and §14: the compiler-provided modules in
`compiler/bind.lua`, the loader's skip of `library` for those names in
`compiler/loader.lua`, the switch from `node.name` to `target.name` in
`compiler/check.lua` and `compiler/lower.lua`, the unconditional
`__wlo_run(main, ...)` in `compiler/emit.lua`, the `__wlo_argv` and
`__wlo_args(site)` rewrite in `runtime/core.lua`, the rewritten examples, the
new `tests/modules/shadow_sys` program, and the updated unit and program tests.
Traced `lookup`, `resolve_named`, `declare`, and the `MethodCall` branch of
`resolve_expression` for the source-less module tables, the `CallStmt` transfer
test for a shadowing `exit`, and the emitted helper call for `args`.

Gaps:

- None material.

## Summary

No findings.

## Checks run

- `make test`: 204 passed, 0 failed, including the new `standard_modules`,
  `arguments_reach_sys_args`, `invalid_utf8_argument`, `chars_example`, and
  `shadow_sys` tests.

## Verdict

The slice matches the plan and the specification. The compiler-provided modules
bind through the existing module lookup, the loader finds them after the entry
directory and before `library`, built-in behavior keys on the target so a
shadowing module's functions are ordinary calls, and arguments are validated only
when `sys.args()` runs. Nothing needs to change.
