# Text conversions

## Goal

Implement the text conversions in `docs/spec.md` §6 and §7: `int(str)` and
`float(str)` alongside the numeric conversions, and the built-ins
`ord(str) -> int` and `chr(int) -> str`, with the specified `ValueError`
messages and results that match Python's for the accepted forms.

## Related code

- `compiler/bind.lua` — `builtins` table of built-in names.
- `compiler/check.lua` — `builtins` signatures (`int` takes `float`, `float`
  takes `int`) and the `Call` case of `check_expression`, which checks `"any"`
  arguments of `print`, `eprint`, `str`, and `len` by name.
- `compiler/lower.lua` — the `Call` case: `float` lowers to its argument, other
  built-ins to a helper of the same name.
- `runtime/core.lua` — `__wlo_MAX_INT`, `__wlo_int` (float to int),
  `__wlo_fail`, `__wlo_CODE_POINT`, and `__wlo_code_points`.
- `tests/unit/check_test.lua:93` — the current `int(1)` and `float(1.5)`
  rejections; `tests/unit/lower_test.lua:232` — conversion lowering.

## Decisions

- **Checking conversions.** `int` and `float` take an `"any"` argument and are
  checked by name like `str`: `int` accepts `float` or `str`, `float` accepts
  `int` or `str`. Any other argument type, including an optional, reports
  `cannot convert a value of type <T> to int` (or `to float`) at the argument,
  matching the existing `str` message. `int(int)` and `float(float)` stay
  errors, since the spec lists neither.
- **`ord` and `chr`** are ordinary entries in both `builtins` tables:
  `ord = { params = { "str" }, result = "int" }` and
  `chr = { params = { "int" }, result = "str" }`. They lower to the helpers
  `__wlo_ord` and `__wlo_chr` through the existing same-name path.
- **Helper names.** `int(str)` lowers to `parse_int` and `float(str)` to
  `parse_float`. The `str_` prefix is taken by string methods and
  `__wlo_str_float` already formats a float, so `str_int`/`str_float` would
  collide or mislead. `int(float)` keeps `__wlo_int`; `float(int)` keeps
  lowering to its argument.
- **`__wlo_parse_int(text, site)`** matches `^([-+]?)0*(%d+)$`. Leading zeros
  are dropped by the pattern, so more than 16 remaining digits is out of range;
  otherwise `tonumber(digits)` is exact up to 2^53 and every larger 16-digit
  value rounds to at least 2^53, so `> __wlo_MAX_INT` detects the rest. A
  negative zero is returned as `0`. Failures raise `ValueError`
  `cannot convert str to int`.
- **`__wlo_parse_float(text, site)`** splits an optional sign, then:
  - `inf` or `infinity` in any case gives `±math.huge`; `nan` gives `0 / 0`.
  - Otherwise the rest must match `^(%d*%.?%d*)$` or
    `^(%d*%.?%d*)[eE]([-+]?%d+)$` with at least one digit in the mantissa, which
    rejects whitespace, underscores, hexadecimal, and a lone `.`.
  - The value is `tonumber(sign .. mantissa .. "e" .. exponent)`. LuaJIT's
    decimal scanner rounds to nearest exactly as Python does (checked against
    Python on 6000 random and halfway-case inputs) and overflows to infinity,
    but it rejects exponents of 2^20 or more, so the exponent is clamped to
    ±999999 first. That clamp changes no result unless the mantissa has
    hundreds of thousands of digits.
  - Failures raise `ValueError` `cannot convert str to float`.
- **`__wlo_ord(text, site)`** raises `ValueError` `expected one character`
  unless `__wlo_code_points(text) == 1`, then decodes the UTF-8 bytes: the
  first byte modulo `2 ^ (7 - #text)` for multibyte sequences, then six bits
  from each continuation byte.
- **`__wlo_chr(n, site)`** raises `ValueError` `invalid code point` for
  `n < 0`, `n > 0x10FFFF`, or `0xD800 <= n <= 0xDFFF`, then encodes one to
  four UTF-8 bytes with `string.char`, `math.floor`, and `%`.

## Test plan

- `tests/unit/check_test.lua`: `int(s)` and `float(s)` with `s: str` type as
  `int` and `float`; `ord("a")` is `int` and `chr(97)` is `str`; `int(1)`,
  `float(1.5)`, and `int(True)` report the new conversion message; `ord(1)` and
  `chr("a")` report `expected str, received int` and
  `expected int, received str`.
- `tests/unit/lower_test.lua`: `int(s)` lowers to `parse_int(s)#1`, `float(s)` to
  `parse_float(s)#1`, and `ord`/`chr` to same-named helpers.
- `tests/programs/text_conversions.wlo` with `.out`, every expected line
  checked against Python. A helper per conversion catches `ValueError` and
  prints its message, so one program covers accepted and rejected forms:
  - `int`: `0`, `-0`, `+7`, `007`, `-9007199254740991`, `9007199254740991`
    accepted; `9007199254740992`, `-9007199254740992`, a 20-digit value, `""`,
    `"+"`, `" 1"`, `"1_000"`, `"1.0"`, `"0x10"` rejected.
  - `float`: `7`, `2.5`, `.5`, `5.`, `1e-3`, `-1E+3`, `+0.0`, `-0.0`, `inf`,
    `-Infinity`, `NaN`, `0.1`, `9007199254740993` (rounds to even),
    `1.7976931348623157e308`, `1e309` and `1e99999999999` (infinite),
    `1e-400` and `1e-99999999999` (zero), `5e-324` accepted; `""`, `"."`,
    `"e5"`, `"1e"`, `" 1"`, `"1_0"`, `"0x10"`, `"infinit"`, `"1e5.0"`
    rejected.
  - `ord` and `chr`: `ord("a")`, `ord("é")`, `ord("€")`, `ord("😀")`, and
    `chr` of each result printed back; `chr(0x7F)`, `chr(0x80)`, `chr(0x7FF)`,
    `chr(0x800)`, `chr(0xFFFF)`, `chr(0x10000)`, `chr(0x10FFFF)` round-tripped
    through `ord`; `ord("")` and `ord("ab")` rejected; `chr(-1)`, `chr(0xD800)`,
    `chr(0xDFFF)`, and `chr(0x110000)` rejected.

## Implementation plan

1. `compiler/bind.lua`: add `ord` and `chr` to `builtins`.
2. `compiler/check.lua`: change `int` and `float` to `params = { "any" }`, add
   `ord` and `chr`, and add the `int`/`float` argument checks beside the `str`
   check in the `Call` case.
3. `compiler/lower.lua`: in the `Call` case, lower `float` of a `str` to the
   `parse_float` helper and only pass other `float` arguments through; pick
   `parse_int` for `int` of a `str` in the `Builtin` branch.
4. `runtime/core.lua`: add `__wlo_parse_int` and `__wlo_parse_float` after
   `__wlo_int`, and `__wlo_ord` and `__wlo_chr` after `__wlo_str_join`.
5. Add the unit and program tests above and update the two existing
   `check_test.lua` expectations.
6. `agents/todo.md`: check off the fifth slice.
