# Tuple comparisons, iteration, and defaults

## Scope and coverage

Reviewed the staged implementation of
`agents/plans/2026-10-19-003-tuple-comparisons-iteration-and-defaults.md`:
tuples in `types.comparable`, the new `types.ordered` and `types.items`, the
ordering, `For`, and `copy_default` changes in `compiler/check.lua`, tuple
equality, ordering, `list_contains_converted`, and tuple `for` conversion in
`compiler/lower.lua`, tuple defaults in `parse_default` and bind's
`default_type`, the `__wlo_equal`, `__wlo_tuple_order`, `__wlo_tuple_items`,
and `__wlo_list_contains_converted` runtime helpers, the `agents/todo.md` edit,
and the new tests. Traced equality conversion through boxed positions,
optionals, nested tuples, enum and bytes positions; ordering through nested
tuples, strings, empty tuples, and NaN; `for` over narrowed optionals, aliases,
and tuples whose positions need boxing; and defaults with nested tuples and
enum members, against spec §3, §5, §7, and §8.

Gaps:

- None material. `examples/rosettacode/factorial.wlo` and
  `fibonacci_sequence.wlo` already fail before this change and were not
  reviewed. Tuple sorting and tuple `iter` methods belong to later tasks in
  `agents/todo.md` and were not reviewed.

## Summary

No findings.

## Checks run

- `make test`: 281 passed, 0 failed.
- Focused programs for alias tuples, enum and bytes positions, nested float
  ordering, nested tuple defaults, `()` defaults, iteration over tuples of
  tuples with boxing, narrowed optional tuples, and `int | None` positions in
  `==` and `in`: all outputs matched Python semantics.
- Diagnostics for `() < ()`, `(1, None) < (1, None)`, and iteration over
  tuples with two tuple members: as specified.
- Rosetta Code examples against their `.out` files: only `factorial.wlo` and
  `fibonacci_sequence.wlo` differ, as before. `willow check` on the stdlib and
  project examples: all pass.

## Verdict

The change meets the plan and spec §7 with no findings.
