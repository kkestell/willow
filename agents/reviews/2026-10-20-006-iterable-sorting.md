# Iterable sorting

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-006-iterable-sorting.md`:
`check_iterable` and `check_sortable` in `compiler/check.lua` and their use by
`for`, `sorted`, and `list.sort`; `items_iterator` and the `sorted` lowering in
`compiler/lower.lua`; `__wlo_has_nan`, `__wlo_sorted_values`, and
`__wlo_sort_items` in `runtime/core.lua`; the new unit and program tests; and
the `sorted` rewrites of `report.wlo`, `listing.wlo`, `kv/server.wlo`, and
`associative_array_iteration.wlo`. The review read them against spec §3
(iterable borrowing) and §7 (`sorted` and `sort`), and traced the runtime
helpers they call: `__wlo_iterate`, the `<kind>_items` iterators,
`__wlo_equal`, and `__wlo_tuple_order`.

Gaps:

- The kv server example was type-checked, not run; its tests passed before
  staging and the fix does not touch it.

## Summary

| ID | Severity | Category   | Fix   | Title                                         |
| -- | -------- | ---------- | ----- | --------------------------------------------- |
| F1 | Low      | Simplicity | Fixed | `check_sortable` restates `types.ordered`     |

## F1. `check_sortable` restates `types.ordered`

Low · Simplicity · Fixed · `compiler/check.lua:567`

`check_sortable` accepted an item type when it was in the `SORTABLE` table of
`int`, `float`, and `str`, or was a tuple with `types.ordered(item, item)`. It
also guarded against a missing item type. `types.ordered(t, t)` already holds
exactly for `int`, `float`, `str`, and tuples of ordered positions, so the table
and the tuple branch repeat it. The guard is unreachable: `check_iterable`
raises its diagnostic before returning no item, and a list always has an
element type.

### Fix

`check_sortable` now tests `types.ordered(item, item)` alone, and the
`SORTABLE` table is removed. The diagnostics are unchanged.

## Checks run

- A scratch program sorted a class whose `iter` returns a user iterator, a
  list iterator, a dictionary iterator, a tuple of tuples, and generators with
  `reverse` given positionally and by keyword before `items`. Each printed the
  expected order. `iter` ran once, and the arguments ran in the order they
  were written.
- `sorted(3)`, `sorted([[1]])`, a `dict` with tuple keys, and a non-`bool`
  `reverse` each reported one diagnostic.
- The compiled Lua for `sorted(d, reverse=True)` calls
  `__wlo_sort_items(__wlo_dict_items(d, 1), true, 2)`.
- `make test` after the fix: 335 passed, 0 failed.
- `./willow check` on the four updated examples passed, and
  `associative_array_iteration.wlo` printed its expected output.

## Verdict

The change meets the plan and spec §7 for `sorted` without `key`. F1 removed a
redundant type table, and the code is ready to commit.
