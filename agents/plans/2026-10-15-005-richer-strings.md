# Richer strings

## Goal

Add triple-quoted strings, `\x`, `\u`, and `\U` escapes, f-strings, `str(...)`,
string ordering, `len`, `in`, the §17 methods, and `for` over strings (willow.md
§17). When done, the §17 example checks, builds, and runs with the output in its
comments; string results match Python, counting code points; and `print`,
`str(...)`, and f-string fields produce the same text for the same value.

## Related code

- `compiler/lexer.lua` — `read_string`, `lex_line`, and the line loop in
  `M.lex`, which assumes every token ends on its own line.
- `compiler/parser.lua` — `parse_primary` (the `int (` and `float (` conversion
  calls), `expression_starts`, and `descriptions`.
- `compiler/bind.lua` — `builtins` and `resolve_expression`.
- `compiler/check.lua` — `builtins`, `ORDERING`, `item_type`, `method_signature`,
  the `print` and `len` checks in the `Call` branch.
- `compiler/lower.lua` — the `Call`, `MethodCall`, `Binary` `in`, and `For`
  branches, and `is_pure`.
- `compiler/emit.lua` — `expr`.
- `runtime/core.lua` — `__wlo_print`, `__wlo_print_float`, `__wlo_format_float`,
  `__wlo_len`, and the iterators.

## Decisions

### Lexing

- **Lines.** A helper `line_end(pos)` returns the line terminator's first byte
  (or one past the end) and the newline position. `lex_line(pos)` computes its
  own end with it, recomputes the end after any string, and returns the final
  `stop` and `newline`, which the line loop uses for the `NEWLINE` token and the
  next line. The loop body of `lex_line` becomes `lex_token(pos, last)`, which
  reads one token and returns the next position, or nil at a comment.
- **Strings.** `read_string(start, last, formatted)` handles all forms. Three
  quote characters open a triple-quoted string, whose limit is the end of the
  source instead of the line. Inside it, LF adds `\n` and advances `line` and
  `line_start`, and CR is skipped (the source is already validated, so it is
  part of CRLF). The token's span is computed at the opening before any lines
  are crossed. An unterminated string reports that opening span.
- **Escapes.** `read_escape(pos, last)` returns the text and next position. `\x`,
  `\u`, and `\U` need exactly 2, 4, and 8 hex digits
  (`escape '\x' needs 2 hexadecimal digits`); a surrogate or a value above
  U+10FFFF is `escape '\uD800' is not a valid code point`. A local
  `utf8_encode(code)` produces the bytes.
- **F-strings.** An identifier `f` directly followed by a quote starts an
  f-string. `{{` and `}}` add literal braces; a lone `}` is
  `single '}' is not allowed in an f-string`. A `{` starts a field, found by
  scanning to the `}` that closes it while counting `( [ {` nesting and skipping
  strings in the other quote character. Inside a field a backslash, a `#`, or
  the f-string's own quote character is an error
  (`f-string fields cannot contain ...`), and at nesting zero `:` is
  `format specifications are not supported` and `!` not followed by `=` is
  `conversions are not supported`. A field holding only spaces is
  `empty f-string field`. The field's tokens are then lexed with `lex_token`
  from their original positions into a separate list ending in a `FIELD_END`
  token at the `}`, so spans inside fields are exact; a line break in a
  triple-quoted field advances the line as in strings.
- An f-string is one `FSTRING` token whose value is a list of parts: strings for
  literal text and token lists for fields.

### Parsing

- `FSTRING` becomes `FString { parts }`, where each part is a string or an
  expression. Each field is parsed by swapping the parser's `tokens` and `pos`
  to the field's list, parsing one expression, and expecting `FIELD_END`
  (described as `'}'`).
- `str (` joins `int (` and `float (` as a conversion call named `str`.

### Binding and checking

- `str` joins the built-in targets. Resolution walks f-string fields.
- `str(x)` takes one printable argument
  (`cannot convert a value of type <type> to str`) and returns `str`. An
  f-string field must be printable (`cannot format a value of type <type>`);
  the f-string has type `str`.
- `ORDERING` gains `str str`. `len` accepts `str`. `item_type("str")` is `str`,
  so `sub in s` and `for ch in s` work through the existing rules.
- `method_signature` on `str`: `startswith(str) -> bool`,
  `endswith(str) -> bool`, `find(str) -> int`, `replace(str, str) -> str`,
  `strip() -> str`, `split(str) -> list[str]`, `join(list[str]) -> str`.

### Lowering, emission, and runtime

- One formatting routine per static type family: `__wlo_str(value)` writes
  `None`, `True`, `False`, integers, and strings; `__wlo_str_float(value)` writes
  `None` or `__wlo_format_float(value)`. `__wlo_print` and `__wlo_print_float`
  write their result, and `str(...)` and f-string fields call them too.
- A new lowered expression `Str { value, float }` emits `__wlo_str(v)` or
  `__wlo_str_float(v)`. It cannot fail and its operand is already evaluated, so
  it stays inline. A `str`-typed value needs no conversion.
- `str(x)` lowers to `Str` of its operand (or the operand itself for a `str`).
- An f-string lowers each field with `lower_operand` in order, converts it with
  `Str` where needed, and builds `Concat { parts }`, which emits
  `"a" .. __wlo_str(x) .. "b"`. An f-string with no fields is a `Literal`; one
  part alone is that part. `is_pure` treats an f-string as pure when its fields
  are.
- Method, `in`, and `for` helpers on strings use the `str_` prefix:
  `str_startswith`, `str_endswith`, `str_find`, `str_replace`, `str_strip`,
  `str_split`, `str_join`, `str_contains`, and `str_items`. `__wlo_len` counts
  code points for a Lua string.
- Runtime string helpers work on bytes, which is exact because every Willow
  string is valid UTF-8 and a valid UTF-8 needle only matches at code point
  boundaries. Code points are counted and iterated with the pattern
  `[^\128-\191][\128-\191]*`. `find` converts the byte index to a code point
  index; `replace` with an empty `old` inserts `new` around every code point;
  `strip` removes space, tab, LF, VT, FF, and CR; `split` fails with
  `empty separator` (category `value`) and otherwise splits with plain `find`;
  `join` uses `table.concat` over `1..n`. Ordering uses Lua's `<` on strings,
  which compares bytes and therefore code points.

## Test plan

- `tests/unit/lexer_test.lua`: triple-quoted strings with LF and CRLF line
  breaks, keeping indentation, with escapes, and followed by tokens on a later
  line with correct spans; unterminated triple-quoted strings; bare CR still
  rejected inside one; `\x41`, `é`, `\U0001F600`, `\U0010FFFF` values;
  short hex digits, `\uD800`, and `\U00110000` rejected; f-string parts with
  `{{` and `}}`, nested brackets and dict displays, strings in the other quote,
  and a field token's span; lone `}`, empty field, backslash, `#`, own quote,
  `:` format spec, and `!r` conversion rejected; `!=` allowed.
- `tests/unit/parser_test.lua`: f-string parts as expressions; a syntax error
  inside a field points into the field; `str(x)` as a call.
- `tests/unit/check_test.lua`: f-string and `str(...)` types; non-printable
  fields and arguments rejected; string ordering; `len`, `in`, every method's
  types and a wrong argument; `for ch in s` gives `str`; indexing a string
  rejected.
- `tests/unit/lower_test.lua`: f-string fields evaluated in order into a
  `Concat`; `str(...)` of a float uses `str_float`; `str` of a string adds no
  conversion.
- `tests/programs/strings.wlo` with `.out`: the §17 example; triple-quoted
  strings; numeric escapes; f-strings with every scalar type, optionals,
  `{{`/`}}`, nested calls, and evaluation order; `str` of every scalar; non-ASCII
  `len`, `find`, iteration, and ordering; `startswith`, `endswith`, `replace` with
  empty and repeated `old`, `strip`, `split` with repeated and edge separators,
  `join`. Expected output comes from running the program in Python.
- `tests/programs/split_empty_separator.wlo` with `.err`.

## Implementation plan

1. `compiler/lexer.lua`: `line_end`, `lex_token`, `lex_line`, `read_escape`,
   `utf8_encode`, triple-quoted strings, and f-strings.
2. `compiler/parser.lua`: `FString`, field parsing, `str(...)`.
3. `compiler/bind.lua`: `str` built-in and f-string fields.
4. `compiler/check.lua`: `str(...)`, f-strings, ordering, `len`, `item_type`,
   string methods.
5. `compiler/lower.lua`: `Str`, `Concat`, f-strings, `str(...)`, and `str_`
   helpers.
6. `compiler/emit.lua`: `Str` and `Concat`.
7. `runtime/core.lua`: `__wlo_str`, `__wlo_str_float`, printing through them,
   `__wlo_len` on strings, and the string helpers.
8. Tests as listed above.
9. `examples/strings.wlo`: formatting a small report with f-strings, `split`,
   `join`, `strip`, and `for` over a string; check, build, and run it.
10. `agents/todo.md`: tick the milestone.
