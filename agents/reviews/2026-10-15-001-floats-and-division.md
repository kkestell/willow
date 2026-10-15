# Review: Floats and division

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-15-001-floats-and-division.md` against `willow.md` §12 and §13 and `AGENTS.md`: `compiler/lexer.lua`, `compiler/parser.lua`, `compiler/bind.lua`, `compiler/check.lua`, `compiler/lower.lua`, `compiler/emit.lua`, `runtime/core.lua`, the unit and program tests, `examples/floats.wlo`, and `agents/todo.md`. Also read the surrounding lowering code (`helper`, `lower_operand`, `lower_short_circuit`, the `CallStmt` path) that the new builtins pass through.

The implementation lowers float `*` to `__wlo_float_mul` instead of the plan's inline `*`. On arm64, LuaJIT's dual-number mode multiplies integer-valued operands as integers, so `0.0 * -1.0` would give `0.0` instead of `-0.0`. Scratch programs confirmed that `+`, `-`, and unary `-` keep `-0.0` in both the interpreter and hot traces, so only `*` needs the helper. The helper registers a site it never uses and makes float `*` hoist into temporaries. That costs a little readability in the generated Lua but has no effect on behavior.

All runs were on macOS arm64. Linux x64, where LuaJIT does not use dual-number mode, was not exercised.

## Fixed

- **`float(x)` hoisted a call operand into a temporary** (`compiler/lower.lua:116`): `x = float(f(1))` emitted `__wlo_t1 = f(1)` followed by `x = __wlo_t1`, which made the Lua less readable for no reason. `float(x)` now lowers through `lower_value` of its operand, the same way unary `+` does, so the output is `x = f(1)`, and a `float(f(1))` statement emits `f(1)`. The `lower_test.lua` conversion expectations were updated to match.

## Findings

No open findings.

## Checks run

- `make test`: `98 passed, 0 failed`, before and after the fix.
- Ran 6,294 float literals through `print` (random binary64 bit patterns, every seventh power of two from `2^-1074` to `2^1023`, and short decimals) and compared the output with Python `repr`: identical.
- Ran `/`, `//`, and `%` over signed zeros, ±1, subnormal and infinite operands, and `0.1` divisors for 100 iterations each, so they ran under the JIT, and compared with Python: identical.
- Ran a scratch hot loop over `-x`, `-0.0 + x * -1.0`, `0.0 - x`, and `-0.0 - x`, with `x` an integer-valued float produced by `float(i - i)`, and compared the printed signs with the IEEE results: correct.
- Checked diagnostics for a bare `int`, assignment to `float`, `/=`, `**`, `x: float = 1`, `1.`, `1e`, `0.5e+`, and `int(1.5, 2)`: each gives the expected error.
- Built a scratch program to confirm the lowering fix: `x = float(f(1))` emits `x = f(1)` and the statement `float(f(2))` emits `f(2)`.
- Ran every program in `examples/`: all succeed.

## Verdict

The milestone meets §13: literals, typing, division semantics, conversions, runtime failures, and `repr`-compatible formatting all match Python in the cases tested. One low-severity lowering issue was fixed, and no findings remain open.
