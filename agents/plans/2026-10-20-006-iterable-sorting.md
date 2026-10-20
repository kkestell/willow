# Iterable sorting and tuple ordering

## Goal

First task of the sorting milestone (spec §7 Lists and dictionaries, Tuples):

- `sorted(items, reverse=False)` accepts any `Iterable[T]`: lists, dicts (their
  keys), strings, bytes, tuples, ranges, classes, protocol values, and
  generators. It consumes the iterable fully into a new list before sorting.
- `T`, for `sorted` and `list.sort`, may be `int`, `float`, `str`, or a
  comparable tuple (positions of the same ordered type, recursively). Tuples
  sort lexicographically, as `<` compares them.
- NaN anywhere in an element, including inside a tuple, raises `ValueError`
  `cannot sort NaN`, and the input is left unsorted.
- `report.wlo`, `listing.wlo`, and `kv/server.wlo` call `sorted` on their
  dictionaries instead of `keys` helpers, and
  `associative_array_iteration.wlo` sorts the dictionary instead of copying its
  keys into a list.

`key` callbacks are the next task.

## Related code

- `compiler/stdlib.lua`: the `sorted` built-in (`items: "any"`, `reverse`).
- `compiler/check.lua`: `SORTABLE`, `check_sortable`, the `sorted` call, the
  `list.sort` method, and the `For` branch, which finds the item type of a
  built-in or `Iterable[T]` iterable and stores `iter_call`/`next_call`.
- `compiler/types.lua`: `ordered`.
- `compiler/lower.lua`: the `For` branch, which builds the Lua iterator for any
  iterable (`<kind>_items`, `range`, or `iterate`).
- `runtime/core.lua`: `__wlo_sorted_values`, `__wlo_sorted`,
  `__wlo_list_sort`, `__wlo_tuple_order`, `__wlo_equal`.

## Decisions

- **Shared iteration.** The `For` branch's item lookup moves into
  `check_iterable(node, holder, state)`, which checks the iterable `node`,
  stores `iter_call` and `next_call` on `holder` for protocol iteration, and
  returns the item type (or reports "cannot iterate over T"). `for` and
  `sorted` both use it. In lowering, the `For` branch's iterator construction
  moves into `items_iterator(holder, iterable, item_type, span)`, also shared.
- **Sorting any iterable.** A list argument keeps the `sorted` helper, which
  copies. Any other iterable lowers to `sort_items(iterator, reverse)`, which
  collects the Lua iterator's items into a new list and sorts it in place.
- **Sortable types.** `check_sortable` accepts `int`, `float`, `str`, and tuples
  with `types.ordered(t, t)`, for both `sorted` and `list.sort`.
- **Run time.** `__wlo_sorted_values` checks every element with
  `__wlo_has_nan`, which looks inside tuples, before ordering anything. It
  orders elements with `__wlo_tuple_order(a, b, "<")` for tuples and `<`
  otherwise, keeping equal elements (by `__wlo_equal` for tuples) in input
  order in either direction.

## Test plan

- `tests/unit/check_test.lua`: `sorted` of a `dict[str, int]` has type
  `list[str]`; `sorted([(1, 'a')])` is accepted; `sorted([(1, [2])])`,
  `sorted([1, 2.5])` (a union), and `sorted(3)` report their errors; `.sort()`
  on `list[tuple[str, int]]` is accepted.
- `tests/programs/sorting.wlo` and `.out`:
  - `sorted` of a dict, a string, bytes, a tuple, a range, a generator, and an
    `Iterable[int]` protocol value; `reverse=True`;
  - tuples sorted by their first position, ties broken by later ones, and
    nested tuples; stable order for equal tuples in both directions;
  - `cannot sort NaN` for a float list, a tuple holding NaN, and `list.sort` of
    tuples, with the list unchanged afterwards.
- The four examples print what they printed before.
- `make test` passes.

## Implementation plan

1. Check: `check_iterable`, `check_sortable`, and the `sorted` call.
2. Lower and runtime: `items_iterator`, `sort_items`, NaN checks and tuple
   ordering in `__wlo_sorted_values`.
3. Tests, then the examples, each run before and after.
4. Check off the task in `agents/todo.md`.
