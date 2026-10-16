# Readable function and record APIs review

## Scope and coverage

Reviewed the staged implementation of `agents/plans/2026-10-16-001-readable-function-and-record-apis.md` against the plan and `docs/spec.md` §3, §5, §7, and §14: `parse_default`, `parse_optional_default`, and the positional-after-keyword check in `compiler/parser.lua`; the default type check in `compiler/bind.lua`; `bind_args`, `builtin_params`, the `builtins` names and defaults, and the `Call`, `MethodCall`, and `For` call sites in `compiler/check.lua`; `lower_args` and its interaction with `lower_operand`, `spill`, and `is_pure` in `compiler/lower.lua`; the unit and program tests; `examples/banner.wlo`; and the spec and todo updates. No material gaps.

## Fixed

None.

## Findings

No open findings.

## Checks run

- `make test`: 215 passed.
- Ad hoc programs: keywords on `int` and `str` conversions are rejected as positional-only; `P(1, x=2)`, `f(1, 2, a=3)`, and `xs.sort(True, reverse=False)` report a second value; `f(b=1, a=2)` with only `a` reports the unknown name; `f(b=1)` reports the missing argument; `x: float = 1` is rejected as `x: float` rejects `f(1)`; a trailing comma after a keyword argument parses.
- Written evaluation order: `f(b=p.n, a=bump(p))` reads `p.n` before `bump` runs (`1 0`), and `f(b=xs[5], a=g())` raises `IndexError` before `g` runs.
- Defaults on parameters and fields whose types are aliases declared after the record (`Label = str | None`, `Num = int | float`) check and run correctly.

## Verdict

The implementation matches the plan and the spec. No findings.
