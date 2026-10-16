# Text and collection essentials

## Goal

Implement `docs/spec.md` §15: string indexing, string and list slicing, negative
indexes, `sorted` and `list.sort` with an optional `reverse`, Unicode 17.0
`lower` and `upper`, `ljust` and `rjust`, and f-string format specifications.
Deliver a word-frequency report example, measure sequential Unicode scanning
against the JSON parser's representation, and fold §15 into the baseline spec.

## Related code

- `compiler/lexer.lua` `read_field` — scans an f-string field and fails on a
  colon at nesting 0 (`format specifications are not supported`); tokenizes the
  field up to its `}` and ends the list with `FIELD_END`.
- `compiler/parser.lua` `parse_postfix` (indexing), `parse_args`, the `FSTRING`
  branch of `parse_primary`, and `parse_assignment_or_call` (assignment targets).
- `compiler/bind.lua` `builtins` and `resolve_expression`.
- `compiler/check.lua` — `builtins` signatures, `STRING_METHODS`,
  `method_signature`, the `Call`, `Index`, `MethodCall`, and `FString` branches,
  `IndexAssign`, and the `range` arguments in the `For` branch.
- `compiler/lower.lua` — `is_pure`, `text`, `pure`, `helper`, and the `Call`,
  `Index`, `MethodCall`, and `FString` branches. Method calls lower to
  `__wlo_<kind>_<name>` helpers.
- `compiler/emit.lua` `read_runtime` and the runtime inlining at the top of
  `M.emit`.
- `runtime/core.lua` — `__wlo_check_index`, `__wlo_list_index`,
  `__wlo_list_set`, `__wlo_code_points`, `__wlo_CODE_POINT`, `__wlo_str`,
  `__wlo_str_float`.
- `lib/json.wlo` — `_Parser` holds `chars: list[str]` collected by `for c in text`.
- `tests/programs/list_index_out_of_range.wlo` — uses `items[-1]`, which now
  succeeds.
- `tests/unit/lexer_test.lua:187-190` — expects format specifications to be
  rejected.

## Decisions

- **Slices.** `parse_postfix` parses `[start:stop]` with either bound omitted
  into a `Slice` node `{ object, start, stop }`; a second `:` is
  `slice steps are not supported`. A `Slice` assignment target falls into the
  existing `cannot assign to this expression`. Check accepts `str` and `list`
  objects (`cannot slice a value of type X` otherwise), checks present bounds
  against `int`, and gives the slice the object's type. Lowering evaluates the
  object, start, and stop with `lower_operand` in that order and calls the
  `__wlo_str_slice` or `__wlo_list_slice` helper with `nil` for an omitted
  bound. `Slice` is not pure, like `Index`, so a later call cannot change the
  list before the copy is taken.
- **String indexing.** Check handles `str` in the `Index` branch directly (index
  `int`, result `str`) rather than in `index_types`, so `IndexAssign` keeps
  rejecting strings; its message becomes
  `cannot assign to an index of a value of type str` for `str`. A bad index
  raises `IndexError` `string index out of range`, as in Python.
- **Negative indexes.** `__wlo_check_index` becomes
  `__wlo_normalize_index(i, n)`, which adds `n` once to a negative index and
  returns the index, or nil when it is outside `0 <= i < n`.
  `__wlo_list_index`, `__wlo_list_set`, and `__wlo_str_index` use it.
- **Code-point positions.** Strings whose code-point count equals their byte
  count are ASCII and are indexed and sliced by bytes. Otherwise
  `__wlo_offset(text, k)` scans with `gmatch("()[^\128-\191]")` for the byte
  position of code point `k` (`#text + 1` at the end). Indexing and slicing take
  time proportional to the string's length; the spec promises no more.
  `__wlo_slice_bounds(start, stop, n)` applies the defaults, adds `n` once to
  negative bounds, and clamps both to `0..n`; callers return an empty result
  when `stop <= start`.
- **Keyword arguments.** `parse_args` parses `NAME = expression` as a `Keyword`
  node `{ name, value }` at the name; bind resolves its value. Check's
  `positional_args(node, reverse_index)`, called before the arity check in the
  `Call` and `MethodCall` branches and on `range` arguments, replaces a
  `reverse` keyword at `reverse_index` (2 for `sorted`, 1 for `sort`) with its
  value. Other keywords are errors at the keyword: `keyword arguments are not
  supported` outside `sorted` and `sort`, `'sorted' has no parameter 'x'` for
  another name, and `misplaced keyword argument 'reverse'` when it is not at
  `reverse_index`. §16 replaces this.
- **Sorting signatures.** Check's `builtins` entries and `method_signature`
  gain an optional `required` count (default all parameters); the arity error
  for a range reads `'sorted' expects 1 to 2 arguments, received 3`, as
  `range` does. `sorted` is `{ "any", types.bool }` with `required = 1`, and its
  result is the argument's list type. `sort` is `{ types.bool }` with
  `required = 0` and result `None`. Both require a list whose element type is
  exactly `int`, `float`, or `str` (unions excluded):
  `cannot sort a list of type list[bool]`. Lowering passes a literal `false`
  for an omitted `reverse`. `sorted` becomes a built-in name in `bind`.
- **Sorting runtime.** `__wlo_sorted_values(list, reverse, site)` raises
  `ValueError` `cannot sort NaN` if any element differs from itself, then sorts
  an array of indexes with `table.sort`, comparing values with `<` (or `>` when
  reversed) and equal values by index, which makes the order stable in both
  directions and keeps `-0.0` and `0.0` in input order. `__wlo_sorted` wraps the
  result in `__wlo_list`; `__wlo_list_sort` writes it back into the list, so a
  failure leaves the list untouched.
- **Case conversion data.** `tools/unicode_case.lua`, run with the bundled
  LuaJIT on a directory holding the Unicode 17.0 `UnicodeData.txt`,
  `SpecialCasing.txt`, and `DerivedCoreProperties.txt`, writes
  `runtime/case_data.lua`. Its header comment gives the download URL
  `https://www.unicode.org/Public/17.0.0/ucd/` and the command. The data file
  holds locals:
  - `__wlo_LOWER_RUNS` and `__wlo_UPPER_RUNS`: flat
    `first, last, step, delta` runs of the simple mappings (step 1 or 2, same
    delta), about 200 runs each.
  - `__wlo_LOWER_FULL` and `__wlo_UPPER_FULL`: `[code point] = "UTF-8 text"`
    for the unconditional SpecialCasing entries whose full mapping differs from
    the simple one.
  - `__wlo_CASED` and `__wlo_CASE_IGNORABLE`: flat `first, last` ranges from
    DerivedCoreProperties.
- **Case conversion code.** Hand-written `runtime/case.lua` defines
  `__wlo_str_lower` and `__wlo_str_upper`. ASCII text uses `string.lower` and
  `string.upper` (the runtime never sets a locale). Otherwise each code point
  is decoded, looked up in the full table, then in a code-point map built from
  the runs on first use, and re-encoded. U+03A3 lowercases to U+03C2 when
  Final_Sigma holds (a cased code point before it, skipping case-ignorable ones,
  and none after it, skipping case-ignorable ones), otherwise to U+03C3; the
  property tables are searched by binary search. No other SpecialCasing
  condition is language-independent.
- **Including the case runtime.** Lowering records each helper name in a
  `helpers` set returned with the lowered program. `emit` inlines
  `runtime/case_data.lua` and `runtime/case.lua` after `runtime/core.lua` only
  when `helpers.str_lower` or `helpers.str_upper` is set, since the data is
  about 18 KB. `read_runtime` takes the module name.
- **Justification.** `ljust` and `rjust` are `STRING_METHODS` taking `int`.
  Both and the f-string padding use `__wlo_pad(text, width, align, value)`,
  which pads with spaces to `width` code points (nothing when the text is
  already that long, including any negative width); `^` puts the odd space on
  the right. A nil `align` means left when `value` is a Lua string and right
  otherwise.
- **Format specifications in the lexer.** In `read_field`, a colon at nesting 0
  starts the specification, which runs to the next `}`. The field's tokens end
  at the colon with `FIELD_END`, and the token list gets
  `spec = { align, width, precision, type }` (absent parts nil, numbers as
  numbers). The text must match `[<>^]?`, an optional width, an optional `.`
  and precision, and an optional `s`, `d`, or `f`, with no leading zeros in a
  multi-digit width or precision; otherwise
  `invalid format specification 'TEXT'` at the colon. Precision without `f` is
  `format precision requires type 'f'`. An empty specification is allowed and
  has no effect.
- **Format specifications in the tree.** The `FString` node gains `specs`,
  keyed by the part index of a field that has one. Check requires `str` for
  `s`, `int` for `d`, and `float` for `f`, compared by identity so a union
  fails: `format type 'd' requires int, received int | str` at the field.
  Without a type the field only needs to be printable, as now.
- **Format specifications in lowering.** `f` uses the pure helper
  `__wlo_format_fixed(x, precision)` with a default precision of 6; other
  fields use the existing `text`. A width wraps the text in the pure
  `__wlo_pad` with the given alignment; without one, alignment is `<` for a
  `str` field, `>` for a field with no `str` member, and nil (decided from the
  value) for a union with a `str` member, which then passes the operand as
  `value`.
- **Fixed-point formatting.** `__wlo_format_fixed` returns `nan`, `inf`, or
  `-inf` for non-finite values and otherwise calls C `snprintf` with `"%.*f"`
  through `ffi` (declared once at the top of `runtime/core.lua`). The C library
  converts exactly with ties to even at any precision; LuaJIT's
  `string.format` rejects precisions above 99.
- **JSON scanner.** Keep `chars: list[str]`. String indexing scans from the
  start, so a scanner built on `text[pos]` is quadratic. Measure before
  deciding: time `json.parse` on about 1 MB of ASCII JSON and of JSON with
  non-ASCII strings, once as it is and once with a throwaway copy of
  `lib/json.wlo` that indexes `text` directly, and append the numbers to this
  plan under `## Measurements`. Change the scanner only if the indexing copy is
  faster on both.
- **Spec folding.** The §15 rules move into §2 (format specifications in the
  f-string paragraph), §5 (slicing as a postfix form, keyword `reverse` in
  Calls), §7 (string and list tables, negative indexes, slicing, sorting, case
  conversion, padding, and a `### Format specifications` subsection), and §11
  (`sorted`). The §15 heading stays so later section numbers hold, with one
  sentence saying it is implemented and where its rules now live. The
  milestones introduction and the top-of-file pointer say sections 16–24 are
  the unimplemented ones, and §19's "slicing under §15" becomes "§7". The JSON
  measurement sentence is dropped.

## Test plan

- `tests/unit/lexer_test.lua`: a field with `:>10.2f` yields the spec parts; a
  slice in a field (`{t[1:3]}`) has no spec; `{a:}` is accepted; rejected:
  `{a:05}`, `{a:.01f}`, `{a:x}`, `{a:,}`, `{a:{b}}`, `{a:0>5}`, and
  `{a:.2}` and `{a:.2s}` with the precision message. Replace the old
  `format specifications are not supported` expectations.
- `tests/unit/parser_test.lua`: `a[:]`, `a[1:]`, `a[:-1]`, `a[i:j]` shapes;
  `a[1:2:3]` rejected; `a[1:2] = x` rejected; `sorted(xs, reverse=True)` parses
  a `Keyword`.
- `tests/unit/check_test.lua`: string index type and string index assignment
  rejected; slicing a dict and a non-int bound rejected; `sorted` of
  `list[bool]`, `list[int | None]`, and a record list rejected; `sorted` and
  `sort` arity; keywords on `print`, an unknown keyword on `sorted`, and
  `sorted(reverse=True)` rejected; `xs.sort()` used as a value is `None`;
  `lower`, `upper`, `ljust`, `rjust` types; `{x:d}` on a `str`, `{x:f}` on an
  `int`, and `{v:d}` on `int | str` rejected, `{v:>5}` on `int | str` accepted;
  `sorted` free as a local but not as a declaration.
- `tests/unit/emit_test.lua`: a program without `lower` or `upper` has no
  `__wlo_LOWER_RUNS` in its output; one with `upper` does.
- `tests/programs/text_collections.wlo` and `.out`, checked against Python:
  - String indexes `0`, `-1`, and `-len` on ASCII and non-ASCII text; slices
    with each bound omitted, negative, past either end, and `stop <= start`.
  - List negative indexes and negative-index assignment; `copy = items[:]`
    where appending to the copy leaves the original and mutating a shared
    record through the copy shows in the original.
  - Receiver, start, stop evaluation order using printing functions.
  - `sorted` and `sort` on ints, strings with non-ASCII (code-point order), and
    floats with infinities, `[0.0, -0.0]` and `[-0.0, 0.0]` in both directions
    (stability), `reverse` positional and by keyword; `sorted` leaves its
    argument unchanged; `sort` with NaN raises `ValueError` caught in the
    program and the list prints unchanged.
  - `"straße".upper()`, `"ﬁ".upper()`, `"İ".lower()` and its length,
    `"ΟΔΥΣΣΕΥΣ".lower()`, `"Σ".lower()`, `"ΑΣ'".lower()`, `"ΑΣΑ".lower()`,
    `"ǅ".lower()` and `.upper()`.
  - `ljust` and `rjust` with a smaller, equal, larger, and negative width on
    non-ASCII text.
  - Formatting: the §15 example line; each alignment with `s`, `d`, and `f`;
    `^` with an odd pad; `{0.5:.0f}`, `{2.5:.0f}`, `{2.675:.2f}`; default
    precision; `nan`, `inf`, `-inf`, and `-0.0` with a width; a value longer
    than the width; `True` and `None` with a width (right-aligned); an
    `int | str` field without a type holding each member.
- `tests/programs/string_index_out_of_range.wlo` and `.err`: `"é"[1]` reports
  `IndexError: string index out of range` at the index.
- `tests/programs/list_index_out_of_range.wlo`: use `items[-3]` so it still
  fails.
- `tests/unit/cli_test.lua` `words_example`: pipe a few lines into
  `examples/words.wlo` and compare the report.
- One-off, not committed: compare `lower` and `upper` of every code point (and
  a few Final_Sigma strings) from a generated Willow program with Python's
  output, ignoring code points new in Unicode 17.0, since Python 3.14 has 16.0
  data.

## Implementation plan

1. `runtime/core.lua`: `ffi` and the `snprintf` declaration;
   `__wlo_normalize_index` replacing `__wlo_check_index`; `__wlo_offset`,
   `__wlo_slice_bounds`, `__wlo_str_index`, `__wlo_str_slice`,
   `__wlo_list_slice`; `__wlo_sorted_values`, `__wlo_sorted`,
   `__wlo_list_sort`; `__wlo_pad`, `__wlo_str_ljust`, `__wlo_str_rjust`;
   `__wlo_format_fixed`.
2. `tools/unicode_case.lua` and the generated `runtime/case_data.lua`;
   `runtime/case.lua` with `__wlo_str_lower` and `__wlo_str_upper`.
3. `compiler/lexer.lua`: format specifications in `read_field`.
4. `compiler/parser.lua`: `Slice`, `Keyword` arguments, and `specs` on
   `FString`.
5. `compiler/bind.lua`: `sorted` built-in; resolve `Slice` and `Keyword`.
6. `compiler/check.lua`: `positional_args`, optional arity, `sorted`, `sort`,
   the new string methods, string `Index`, `Slice`, `IndexAssign` message, and
   format types.
7. `compiler/lower.lua`: `Slice`, `sorted` and `sort` defaults, formatted
   fields, `is_pure` for `Slice`, and the `helpers` set.
8. `compiler/emit.lua`: conditional case runtime.
9. Tests listed above; update `list_index_out_of_range.wlo`.
10. `examples/words.wlo`: read lines with `input()`, lowercase, split on spaces,
    skip empty words, count in a `dict[str, int]`, then print a header and one
    row per word with `f"{word:<12}{count:>6d}{share:>8.1f}%"`, ordered by count
    descending (`sorted` of the distinct counts with `reverse=True`) and then by
    word (`sorted` of the words with that count).
11. Measure the JSON scanner as described and record the numbers.
12. Fold §15 into `docs/spec.md` and check off the milestone in
    `agents/todo.md`.

## Documentation updates

- `docs/spec.md` as described under Spec folding.
- `agents/todo.md`: check off "Text and collection essentials (spec §15)" and
  its items.

## Measurements

`willow run` of a program calling `json.parse` on a generated array of records,
on macOS (Apple silicon). "Indexing" is a throwaway copy of `lib/json.wlo` that
stores the text and its length and reads `text[pos]`.

| Input | `chars: list[str]` | Indexing |
| --- | --- | --- |
| 8 KB ASCII | 0.03 s | 1.9 s |
| 10 KB non-ASCII | 0.03 s | 4.4 s |
| 859 KB ASCII | 0.12 s | over 300 s |
| 1.0 MB non-ASCII | 0.14 s | over 300 s |

Each string index counts the text's code points, so indexing is quadratic even
for ASCII. The scanner keeps `chars: list[str]`.
