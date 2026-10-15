# Review: Richer strings

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-15-005-richer-strings.md` against `willow.md` §12 and §17 and `AGENTS.md`: `compiler/lexer.lua`, `compiler/parser.lua`, `compiler/bind.lua`, `compiler/check.lua`, `compiler/lower.lua`, `compiler/emit.lua`, `runtime/core.lua`, the unit and program tests, `examples/strings.wlo`, and `agents/todo.md`. Also read the code the new nodes pass through: the lexer's line loop and bracket depth, `is_pure`, `lower_operand`, `scalar`, and the `print` helpers.

Two departures from the plan are intended: the parser stores f-string literal text as `String` nodes and drops empty text, so every `FString` part is an expression; and an f-string with no parts lowers to an empty string literal.

## Fixed

- **Wrong location for errors on later lines of an f-string field** (`compiler/lexer.lua:155`): in a triple-quoted f-string, a field that spans lines reported errors found by the field scan (format specification, conversion, backslash, `#`, own quote) at the field's opening line with a column past its end, such as `3:23` for an error at `4:6`. The scan now advances `line` and `line_start` at each LF and restores them before the token pass and the empty-field check. Added a lexer test.
- **Line break in a string inside a field gave a garbled error** (`compiler/lexer.lua:177`): `f"""{'a` followed by a line break and `b'}"""` reported `f-string fields cannot contain '` with a raw newline in the message. A string inside a field that crosses a line break now reports `unterminated string literal` at its opening quote. Added a lexer test.

## Findings

No open findings.

## Checks run

- `make test`: `145 passed, 0 failed` before and after the fixes.
- Ran `tests/programs/strings.wlo` under Python 3 with `@dataclass` on the class and a `main()` call appended: output matches `strings.out`.
- Ran `examples/strings.wlo`.
- Ran scratch programs for: nested f-strings in the other quote, f-string fields whose later calls mutate a list read by an earlier field, f-strings and `Concat` inside `+`, `str(...)` and fields of `str | None` and `bool | None`, triple-quoted strings inside brackets, inside an indented block, and with CRLF line endings, an unbalanced field `f"{)(}"`, string indexing, an unknown string method, a lone `}`, and escape errors (short hex digits, `\ud800`).

## Verdict

The milestone meets §17. Literals, escapes, f-strings, `str(...)`, ordering, `len`, `in`, iteration, and the methods behave as specified and match Python. The two diagnostic bugs found are fixed and no findings remain open.
