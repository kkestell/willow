# Library keyword arguments review

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-19-006-library-keyword-arguments.md`: parameter names in `STRING_METHODS` and `method_signature` (`compiler/check.lua`), the `sys.eprint` and `bytes` signatures in `compiler/stdlib.lua`, the keyword-only `frame` in `examples/stdlib/banner.wlo`, and the new tests. Traced the names through `builtin_params` and `bind_args` and the written-order evaluation in `lower_args` (`compiler/lower.lua`), and checked every name against the method and function tables in `docs/spec.md` §5, §7, and §14. Confirmed that every other standard-library function and native method with parameters already has names.

Gaps:

- `iter`, `next`, `enter`/`exit`, and sort `key` callbacks do not exist yet and are later tasks, so they were not reviewed.

## Summary

No findings.

## Checks run

- Ran an ad hoc program calling `replace(new=..., old=...)` with printing arguments, plus `get`, `append`, `split`, `endswith`, `find`, `rjust`, and `sys.eprint` by keyword. Results are correct, and arguments evaluate in written order.
- `make test`: 286 passed, 0 failed.

## Verdict

The change matches the plan and spec. The names match the spec's tables, and the intrinsics, including `bytes`, accept only positional arguments.
