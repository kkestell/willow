# Text and collection essentials review

## Scope and coverage

Reviewed the staged implementation of `agents/plans/2026-10-15-014-text-and-collection-essentials.md` against the plan and `docs/spec.md` §2, §5, §7, and §11: the lexer's format specifications, the parser's `Slice` and `Keyword` nodes, binding of `sorted`, checking of slices, string indexes, keyword `reverse`, optional arity, sortable element types, and format types, lowering of slices, sorting defaults, formatted fields, and the `helpers` set, the conditional case runtime in `emit`, the new `runtime/core.lua` helpers, `runtime/case.lua`, `tools/unicode_case.lua`, the tests, `examples/words.wlo`, and the spec and todo updates.

`runtime/case_data.lua` was not regenerated from the Unicode 17.0 files. It was checked indirectly by comparing case conversion of every code point with Python.

## Fixed

- **Unreachable clause in the format specification check** (`compiler/lexer.lua:156`): `dot == "" and precision ~= ""` can never hold, because the greedy width group takes every digit when no dot follows. The extra clause suggested a case that cannot occur. Removed it.

## Findings

No open findings.

## Checks run

- `make test`: 211 passed, before and after the fix.
- `tests/unit/lexer_test.lua` after the fix: 23 passed. Spot checks confirmed `{1:12}` is accepted and `{1:.}` and `{1:5.}` are rejected.
- `lower` and `upper` of every non-surrogate code point from U+0020 up, compared with Python 3.14 (Unicode 16.0): the only differences are U+A7D3 and U+A7D5, whose uppercase forms U+A7D2 and U+A7D4 are new in Unicode 17.0.
- Ad hoc programs covering empty and union-element list slices, non-ASCII padding, alias types with `d` and `sort`, precision 300, `1e308` with `.2f`, Final_Sigma at the start and inside words, and center alignment. All output matched Python.
- Ad hoc diagnostics: keywords on `str`, `pop`, an exception constructor, and `range` in a `for`; an unknown keyword on `sort`; `sorted` with a non-bool `reverse` and a `list[bool]`; dict slicing; string index assignment; slice assignment and augmented slice assignment; slice steps; nested and unterminated format fields; and `sort` on an `int`. Each produced the expected error.

## Verdict

The implementation matches the plan and the spec. One unreachable check was removed, and no findings remain open.
