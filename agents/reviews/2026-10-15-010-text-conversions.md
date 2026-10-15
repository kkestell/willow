# Review: text conversions

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-15-010-text-conversions.md` against `docs/spec.md` §6 and §7: `compiler/bind.lua`, `compiler/check.lua`, `compiler/lower.lua`, `runtime/core.lua`, `tests/programs/text_conversions.wlo` and `.out`, `tests/unit/check_test.lua`, `tests/unit/lower_test.lua`, and `agents/todo.md`. Also read the checker's `Call` case around the new conversion check, the lowering `Call` case, and the runtime helpers the new code depends on (`__wlo_fail`, `__wlo_MAX_INT`, `__wlo_code_points`).

Gaps:

- Checked on macOS only.
- `float(s)` accepts mantissas with hundreds of thousands of digits but may misround them because the exponent is clamped. The plan accepts this, and this review did not exercise it.

## Summary

No findings.

## Checks run

- `make test`: 184 passed, 0 failed.
- `__wlo_parse_float` on 20,000 generated strings (random digits, fractions, exponents up to 330, subnormals, random bit patterns, and malformed, signed, `inf`, `nan`, whitespace, underscore, and hexadecimal forms) compared bit for bit with Python's `float`. Python results for strings with whitespace, underscores, or non-ASCII text were counted as rejections, as §6 requires. 0 mismatches. Failures raised `ValueError` with `cannot convert str to float`.
- `__wlo_parse_float` on long-mantissa halfway cases (2000 trailing zeros, with and without a trailing `1`), `0.<5000 zeros>1e5000`, a 37-digit exponent, the smallest-subnormal rounding boundary, and the `float` maximum overflow boundary: 0 mismatches with Python.
- `__wlo_parse_int` on 20,000 generated strings (random values to 2^60, values within 20 of ±2^53, leading zeros, and malformed forms) compared with Python's `int` limited to the `int` range: 0 mismatches.
- `__wlo_chr` then `__wlo_ord` for every non-surrogate code point 0 through 0x10FFFF: each round-tripped, was valid UTF-8, and was one code point.
- Compiled and ran a program covering `int(s)` and `float(s)` in arithmetic, f-strings, a narrowed `str | None`, `float(int(s))`, `str(float("-0"))`, and an uncaught `int("x")`. Output matched Python, and the failure reported its location.
- Checker diagnostics for `float(y)` with `y: float | None`, `int([1])`, `float({1: 2})`, `int()`, and `ord(chr(1), 2)`: each reported the expected conversion or arity error.

## Verdict

The change implements the §6 string conversions and the §7 `ord` and `chr` built-ins as the plan specifies, and the results match Python's for every accepted form tested. No findings. Ready to commit.
