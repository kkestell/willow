# Standard library and JSON

## Goal

Implement the seventh slice in `docs/spec.md` §12 and §14. `import name` falls
back to the standard library in `lib/` when the entry file's directory has no
`name.wlo`, and `lib/json.wlo` provides `Json`, `JsonError`, `parse`, and `dump`
written in Willow.

## Related code

- `compiler/loader.lua` — `M.load(path, source)` resolves every import as
  `directory .. name .. ".wlo"` and reports open and read failures at the import.
- `compiler/cli.lua` — derives the installation `root` from `arg[0]` (the
  launcher already resolves symlinks) and uses it for `runtime/stub`; calls
  `loader.load` in `translate`; checks every module path against `-o`.
- `tests/modules/missing_module`, `tests/unit/cli_test.lua`
  (`unreadable_module`, `modules_build_matches_run`) — current loader behavior
  that must not change.
- `/tmp/willow-json/json.wlo` — an earlier prototype `parse` and `dump`; the
  library follows its structure but meets the full §14 rules.

## Decisions

- **Where the library lives.** `M.load(path, source, library)` takes the
  standard library directory with a trailing slash; `cli.lua` passes
  `root .. "/lib/"`. Standard modules get their absolute path as `path`, so
  diagnostics, frames, and the `-o` overwrite check work unchanged.
- **When to fall back.** The loader opens `directory .. name .. ".wlo"` first.
  It tries `library .. name .. ".wlo"` only when that open fails with `ENOENT`
  (the third result of `io.open`, `2` on macOS and Linux), so a local module that
  exists but cannot be read is still an error, as in `unreadable_module`. When
  both opens fail, the loader reports the local open's error, so the
  missing-module message stays `cannot load module 'absent': absent.wlo: No such
  file or directory`.
- **Parser state.** A private record `_Parser` holds `chars: list[str]` (the
  text's code points, collected by `for c in text`) and `pos: int`. `_peek(p)`
  returns `""` at the end. Since `"" in s` is `True`, digit and hex tests go
  through `_is_digit(c)`, which checks `c != ""` first.
- **Errors.** `_error(p, problem) -> JsonError` builds the exception, and callers
  write `raise _error(p, "...")` so the checker sees a transfer. When
  `p.pos >= len(p.chars)` the problem becomes `unexpected end of input`. The
  message appends ` at line L, column C`, one-based, counted in code points up
  to `p.pos`, with a new line after each `\n`. The problems are
  `expected value`, `expected string`, `expected ':'`, `expected ',' or ']'`,
  `expected ',' or '}'`, `expected 'true'` (and `false`, `null`),
  `invalid number`, `invalid escape`, `unpaired surrogate`,
  `control character in string`, and `unexpected text after value`. The
  position is where the problem starts: the offending character, the start of a
  number, or the backslash of an escape.
- **Numbers.** `_number` scans RFC 8259's grammar by hand: optional `-`, then `0`
  or a nonzero digit and more digits, then an optional `.` with at least one
  digit, then an optional `e`/`E`, optional sign, and at least one digit. A
  failed step raises `invalid number` at the number's start. The text without
  fraction or exponent goes to `int(text)`, and on `ValueError` (outside the
  `int` range) to `float(text)`; any other text goes to `float(text)`. `-0`
  becomes `0`, since `int` has no negative zero.
- **Strings.** Escapes are `\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, and
  `\u` with four hex digits in either case. A `\u` in `D800`–`DBFF` must be
  followed by `\u` in `DC00`–`DFFF` and combines with it; any other surrogate
  raises `unpaired surrogate` at the first escape. Characters below U+0020
  raise `control character in string`. Willow has no `\b` or `\f` escape, so
  both directions compare `ord(c)` with 8 and 12.
- **Dumping.** `_dump(value, out)` appends pieces to a `list[str]` and `dump`
  joins them. It tests members with `is None` and `isinstance` in the order
  `bool`, `int`, `float`, `str`, `list`, and leaves `dict` for `else`. A float is
  non-finite when `value - value != 0.0` and then raises
  `cannot encode ` + `str(value)`. `_quote` writes `\"`, `\\`, `\b`, `\f`, `\n`,
  `\r`, `\t`, and `\u00XX` with lowercase hex for other code points below
  U+0020.

## Test plan

- `tests/programs/json_library.wlo` with `.out` (named so it does not shadow
  `json`), each line checked against Python's `json` where the rules agree:
  - Round trips of every member type, nesting, empty `[]` and `{}`, and
    whitespace around and inside values.
  - Number typing with `isinstance`: `0`, `-0`, `9007199254740991` are `int`;
    `9007199254740992`, `1.0`, `1e2`, `-1E-2` are `float`; `dump` writes
    `1.0`, `100.0`, and `1e+20`.
  - Escapes in both directions, `\/`, upper- and lowercase hex, a surrogate
    pair, `é` and `🌳` written as they are, and `\u0001` and `\u001f` dumped.
  - A repeated key keeps its first position and last value.
  - Rejected texts, each caught and its message printed: `""`, `"   "`, `"[1, 2"`,
    `"[1 2]"`, `"{\"a\" 1}"`, `"{1: 2}"`, `"tru"`, `"nul!"`, `"01"`, `"1."`,
    `".5"`, `"-"`, `"1e"`, `"+1"`, `"\"\\x\""`, `"\"\\ud800\""`,
    `"\"\\udc00\""`, a raw tab inside a string, `"1 2"`, and a multi-line text
    whose error is on line 3.
  - `dump` of `float("inf")`, `float("-inf")`, and `float("nan")` prints
    `cannot encode inf`, `cannot encode -inf`, and `cannot encode nan`.
- `tests/programs/json_example.wlo` with `.out`: the §14 example.
- `tests/modules/shadow_json/main.wlo` with a local `json.wlo` whose `parse`
  returns a fixed string, and `main.out` showing the local module wins.
- `tests/unit/cli_test.lua`:
  - `standard_library_build_runs_elsewhere`: build a program that imports
    `json` in a temp directory, copy the executable elsewhere, run it, and
    compare with `run`.
  - `standard_library_through_symlink`: run the same program through a
    symlink to `willow` in a temp directory.
  - `missing_module` and `unreadable_module` keep passing unchanged.

## Implementation plan

1. `compiler/loader.lua`: add the `library` parameter and the `ENOENT`
   fallback described above.
2. `compiler/cli.lua`: pass `root .. "/lib/"` to `loader.load`.
3. `lib/json.wlo`: `Json`, `JsonError`, `_Parser`, `_error`, `_peek`,
   `_advance`, `_is_digit`, `_skip_space`, `_word`, `_hex4`, `_string`,
   `_number`, `_value`, `parse`, `_quote`, `_dump`, and `dump`.
4. Add the tests above.
5. `agents/todo.md`: check off the seventh slice.
