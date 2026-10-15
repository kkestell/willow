# Floats and division

## Goal

Add the `float` type, float literals, `/`, `//`, `%`, and the `int(...)` and
`float(...)` conversions (willow.md §12, §13). When done, the §13 example
checks, builds, and runs with the output in its comments; mixed `int`/`float`
operations are type errors; zero divisors and failed conversions are runtime
errors with accurate locations; and `print` writes floats exactly as Python's
`repr` does.

## Related code

- `compiler/lexer.lua` — number scanning (`c:match("%d")` branch), `keywords`,
  `operators`, and `unsupported`.
- `compiler/parser.lua` — `parse_primary`, `parse_product`, `type_names`,
  `expression_starts`, and `descriptions`.
- `compiler/bind.lua` — `PRINT` and call resolution in `resolve_expression`.
- `compiler/check.lua` — `unary_types`, `binary_types`, `EQUALITY`,
  `ORDERING`, and the `Call` branch, which assumes the only built-in is `print`.
- `compiler/lower.lua` — `helpers`, `is_pure`, and the `Unary`, `Binary`, and
  `Call` branches of `lower_value`.
- `compiler/emit.lua` — `binary_ops` and number literals in `expr`.
- `runtime/core.lua` — `__wlo_fail`, `__wlo_check`, and `__wlo_print`.
- `tests/unit/*_test.lua`, `tests/programs/` — existing patterns for each pass.

## Decisions

- **Literals.** The lexer reads `%d+`, an optional `.%d+`, and an optional
  `[eE][-+]?%d+`. Any letter, digit, `_`, or `.` directly after that makes the
  whole run an `invalid number literal`, so `1.`, `1.e5`, `1e`, `1.5.2`, and
  `1_0` are rejected. A literal with a fraction or exponent is a `FLOAT` token
  whose value is `tonumber(text)`; a value of `math.huge` is `float literal out
  of range`. Leading zeros on the integer part give `integer literal has leading
  zeros` or `float literal has leading zeros`. LuaJIT's `tonumber` rounds
  correctly, so the literal is the nearest binary64.
- **Operators.** `/`, `//`, and `%` move from `unsupported` to `operators`;
  `/=`, `//=`, and `%=` stay unsupported.
- **Conversions.** `float` joins the reserved type names. Because `int` and
  `float` are keyword tokens, `parse_primary` turns `int (` and `float (` into
  a `Call` named `int` or `float`; a bare `int` or `float` is still `expected
  an expression`. Bind resolves `print`, `int`, and `float` through one
  `builtins` table of `{ kind = "Builtin", name = ... }` targets. Users cannot
  declare or assign these names because they are reserved words.
- **Built-in signatures.** Check keeps a table:
  `print = { result = "None" }`, `int = { param = "float", result = "int" }`,
  `float = { param = "int", result = "float" }`. Every built-in takes exactly
  one argument; a missing `param` means any type.
- **Type tables.** Unary `+`/`-` and binary `+ - *` accept `int` or `float`
  pairs and keep the type; `/` maps both pairs to `float`; `//` and `%` keep
  the type; `EQUALITY` and `ORDERING` gain `float float`. Mixed pairs fall
  through to the existing `operator '+' cannot be applied to int and float`.
- **Lowering.** A table keyed by operator and then result type names the
  helper an operation needs:

  ```lua
  local binary_helpers = {
    ["+"] = { int = "add" },
    ["-"] = { int = "sub" },
    ["*"] = { int = "mul" },
    ["/"] = { float = "div" },
    ["//"] = { int = "int_floordiv", float = "floordiv" },
    ["%"] = { int = "int_mod", float = "mod" },
  }
  ```

  Float `+ - *` stay inline as `Binary` with ops `+ - *`; only `str` `+`
  becomes `concat`. Unary `-` on `int` stays the `neg` helper; on `float` it
  is a new inline `Neg` expression. `is_pure` treats an operation as impure
  exactly when it lowers to a helper. `float(x)` lowers to its operand, since
  every Willow integer is already the same Lua number. `int(x)` is the `int`
  helper. `print` becomes `print_float` when its argument's static type is
  `float`, and `print` otherwise.
- **Emit.** `binary_ops` gains `+ - *`. `Neg` emits `-` followed by its
  operand as a nested expression, parenthesized when itself nested, so `-(-x)`
  and `a - (-b)` never form a Lua `--` comment. A number literal that is an
  integer with magnitude at most `2^53 - 1` keeps `%d`; any other uses the
  first `%.<p>g`, `p` from 1 to 17, that reads back as the same value.
- **Division runtime.** `__wlo_div(a, b, site)` fails with `division by zero`
  when `b == 0` (which includes `-0.0`) and returns `a / b`; IEEE division of
  two exact integers is the correctly rounded quotient Python gives. A local
  `__wlo_divmod(a, b, site)` is CPython's `float_divmod`: `math.fmod`, sign
  correction toward the divisor, `copysign(0, b)` for a zero remainder, and
  `floor` with the half-step correction for the quotient. `__wlo_floordiv`
  and `__wlo_mod` return its first and second values. `__wlo_int_floordiv` and
  `__wlo_int_mod` return the same values with `-0.0` normalized to `0`;
  `fmod` and the subtraction are exact for integers in range, and the results
  cannot leave the range. A prototype matched Python on 200,000 random integer
  and float pairs, including the sign and infinity cases.
- **Conversion runtime.** `__wlo_int(x, site)` truncates with `math.ceil` for
  negative values and `math.floor` otherwise, fails with `cannot convert float
  to int` when the result is NaN or outside `±(2^53 - 1)`, and normalizes
  `-0.0` to `0`.
- **Failure categories.** `division` and `conversion`, next to the existing
  `overflow`, `io`, and `vm`.
- **Float formatting.** `__wlo_format_float(x)` returns `nan`, `inf`, or
  `-inf` for non-finite values. Otherwise it takes the sign from `1 / x < 0`
  (which covers `-0.0`) and searches `%.<p>e` for `p` from 0 to 16 for the
  first text that reads back as `|x|`. When a precision fails and its text is
  below `|x|`, it also tries the decimal one unit higher in the last digit
  (`__wlo_digits_up`, a string increment that may carry into a new digit and
  exponent): next to a power of two the lower rounding interval is half as
  wide, and CPython's shortest output is then the decimal above. Trailing
  zeros are stripped from the digits; the exponent selects scientific notation
  (`d[.ddd]e±XX`, at least two exponent digits) when below -4 or at least 16,
  and fixed notation with at least one fractional digit otherwise. A
  prototype matched Python's `repr` on 242,000 values, including every power of
  two.
- **Printing.** `__wlo_print` splits into `__wlo_write(text, site)`, which
  writes, flushes, and reports `io` failures, and the existing scalar
  formatting. `__wlo_print_float(value, site)` writes
  `__wlo_format_float(value)`.

## Test plan

- `tests/unit/lexer_test.lua`: `1.0`, `0.25`, `1e9`, `2.5e-3`, `1E+5`, and `0.5`
  lex as `FLOAT` with the right values; `1.`, `1.e5`, `1e`, `1.5.2`, `01.5`,
  `00e1`, and `1e400` are rejected with their messages and columns; `/ // %`
  lex as operators; the unsupported-operator test drops them and keeps `/=`,
  `//=`, and `%=`.
- `tests/unit/parser_test.lua`: `a + b * c / d // e % f` groups at the `*`
  level, left associative; `int(x)` and `float(1)` parse as calls; `float`
  works as an annotation; a bare `int` in expression position is rejected.
- `tests/unit/check_test.lua`: float literals, float arithmetic, `/` on ints
  giving `float`, `//` and `%` keeping the operand type, float ordering and
  equality, and conversion result types; `1 + 1.5`, `1 == 1.0`, `1 < 1.5`,
  `-'a'`, `int(1)`, `float(1.5)`, and `float()` are errors.
- `tests/unit/lower_test.lua`: float `+ - *` and negation stay inline; `/`,
  `//`, `%` become the helpers per type; `float(f(1))` lowers to the call
  alone; `print` of a float uses `print_float`.
- `tests/programs/floats.wlo` with `.out`: the §13 example; `//` and `%` on all
  sign combinations for ints and floats; `int` boundaries and truncation;
  `-0.0` printing and equality; `inf`, `-inf`, `nan` from arithmetic; NaN
  comparisons; formatting at `1e-4`, `1e-5`, `1e15`, `1e16`, `5e-324`, and
  `1.7976931348623157e308`; float literals round-tripping through emit.
  Expected output comes from running the same program body in Python.
- `tests/programs/division_by_zero.wlo` with `.err`: `%` with a `-0.0`
  divisor inside a called function, reporting the operator column and caller
  frames.
- `tests/programs/float_to_int.wlo` with `.err`: `int` of `inf`, reporting
  `cannot convert float to int` at the call.

## Implementation plan

1. `compiler/lexer.lua`: add `float` to `keywords`; move `/ // %` to
   `operators`; replace number scanning as decided.
2. `compiler/parser.lua`: `float` in `type_names`; `FLOAT int float` in
   `expression_starts`; `FLOAT = "float"` in `descriptions`; a `Float` node in
   `parse_primary`; conversion calls; `* / // %` in `parse_product`.
3. `compiler/bind.lua`: replace `PRINT` with the `builtins` table.
4. `compiler/check.lua`: `Float` literals, the type tables, and built-in
   signatures.
5. `compiler/lower.lua`: `binary_helpers`, `Neg`, `is_pure`, conversions, and
   `print_float`.
6. `compiler/emit.lua`: `+ - *` ops, `Neg`, and float literal text.
7. `runtime/core.lua`: `__wlo_div`, `__wlo_divmod`, `__wlo_floordiv`,
   `__wlo_mod`, `__wlo_int_floordiv`, `__wlo_int_mod`, `__wlo_int`,
   `__wlo_digits_up`, `__wlo_format_float`, `__wlo_write`, and
   `__wlo_print_float`.
8. Tests as listed above; `tests/unit/lower_test.lua`'s `show_expr` learns
   `Neg` and prints non-integer numbers with `%.17g`.
9. `examples/floats.wlo`: a short program using division, conversions, and
   float printing; check, build, and run it.
10. `agents/todo.md`: tick the "Floats and division" milestone.
