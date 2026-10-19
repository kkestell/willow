# Tuple comparisons, iteration, and defaults

## Goal

Continue the tuple milestone in `agents/todo.md` (spec §3 Functions, §5, §7
Tuples and unpacking). Tuples support `==` and `!=` when their positions
support equality, and `<`, `<=`, `>`, `>=` when corresponding positions have the
same ordered scalar type or are comparable tuples, deciding at the first
unequal position. `for` iterates a tuple with the union of its position types,
or `None` for `()`, and rejects a union that is not a valid type. A parameter or
field default may be a tuple of defaults.

## Related code

- `compiler/types.lua` `comparable`, `assignable`, `conflict`, `union`.
- `compiler/check.lua` `ORDERING`/`binary_types`, the `==`/`in` cases of
  `Binary`, `For`, and `bind_args`, which copies defaults per call.
- `compiler/lower.lua` `conversion` and `convert`; the `in` and `==` cases of
  `Binary`, which pick `list_contains_boxed` or the `equal` helper; `For`,
  which uses `prefix(type) .. "items"`.
- `compiler/parser.lua` `parse_default`; `compiler/bind.lua` `check_default`.
- `runtime/core.lua` `__wlo_equal`, `__wlo_list_contains_boxed`, `__wlo_list_items`.

## Decisions

- Equality: `types.comparable` also accepts a tuple member whose positions are
  all comparable. The existing rule then applies unchanged: both operands
  comparable and one operand's type assignable to the other's. Since tuple
  assignability goes position by position, this checks arity and each position.
  It rejects a pair such as `tuple[int, int | None]` and
  `tuple[int | None, int]` where neither type is assignable to the other; that
  case is rare and would need a separate per-position conversion.
- Lowering equality: the `equal` helper is used when either side is boxed, holds
  bytes, or holds a tuple. The operand whose type the other is assignable to
  is the wider one, and only the other operand is converted to it. For scalars
  this gives the same conversion as today's `boxed(left) and left or right`.
  `__wlo_equal` compares two tuples position by position with itself. Arities
  match because a union holds one tuple member and assignability requires equal
  arity.
- `in` on a list: replace `list_contains_boxed` with
  `list_contains_converted(list, value, step)`. It is used when the left type is
  wider than the element type (`assignable(left, element)`) and
  `conversion(element, left)` is non-nil, and it converts each element by
  `step` with `__wlo_convert` before comparing. Otherwise the left operand is
  converted to the element type as today. `in` on a tuple stays unsupported.
- Ordering: `types.ordered(a, b)` is true for two `int`s, two `float`s, two
  `str`s, or two tuples of equal arity whose positions are all `ordered`. The
  ordering operators use it in place of the `ORDERING` table. Tuples lower to the
  pure helper `tuple_order(a, b, op)`: at the first position where values are
  unequal (`__wlo_equal` for nested tuples, `~=` otherwise), it returns that
  position's comparison, recursing for a nested tuple. If no position is unequal,
  it returns whether `op` is `<=` or `>=`. A NaN position is unequal, so its
  comparison is false, matching the scalar operators.
- Iteration: check computes the item type of a tuple in the `For` case only, so
  `in` does not start accepting tuples. A new `types.items(t)` builds it.
  Members of the positions are added in order, skipping a member assignable to
  one already kept and dropping kept members assignable to a new one. No
  members gives `None`. A `types.conflict` among the kept members reports
  "cannot iterate over <type>: <message>". Lowering converts the iterable from
  its type to a tuple of the item type repeated per position (via `convert`),
  then iterates with `tuple_items`, which the existing
  `prefix(type) .. "items"` already names.
- Defaults: `parse_default` accepts `()`, `(d,)`, and `(d1, d2, ...)` of
  defaults as a `TupleDisplay`; a parenthesized default without a comma stays
  an error. Bind's `check_default` becomes a recursive `default_type(default,
  module)` that resolves enum members inside tuples. `bind_args` copies a
  default per call with a recursive `copy_default`, so tuple elements are fresh
  nodes for each call site. Check then types the copy against the parameter
  like any display, which also boxes floats where positions need it.

## Test plan

- `tests/unit/check_test.lua`: `(1, 'a') == (1, 2)` and `(1,) == (1, 2)` are
  rejected; `(1, [1]) == (1, [1])` is rejected; `(1, 'a') < (1, None)` and
  `(1,) < (1.5,)` are rejected; iterating `tuple[list[int], list[str]]` reports
  "cannot iterate over tuple[list[int], list[str]]: a union can have only one
  list member"; `x in (1, 2)` stays rejected.
- `tests/unit/bind_test.lua`: a `tuple[E, int]` default `(E.A, 1)` resolves the
  member; `(1, 'a')` for `tuple[int, int]` reports
  "expected tuple[int, int], received tuple[int, str]".
- `tests/unit/parser_test.lua`: `()`, `(1,)`, and `(E.A, -1)` defaults parse;
  `(1)` is rejected.
- `tests/programs/tuples.wlo`: equality and inequality of tuples, nested
  tuples, `None` positions, `tuple[int, str] | None` against `None` and a tuple,
  and `tuple[float]` against `tuple[int | float]` holding `1` (unequal) and
  `1.0` (equal); ordering across positions, stopping at the first unequal one,
  for equal tuples with `<=`, with nested tuples, with strings, and with a NaN
  position; `(1, 2) in [(1, 2)]` and a converted list `in`; iterating
  `(1, 2.5, None)`, printing each item and testing `isinstance(item, float)`;
  iterating `()`; a function with a tuple default called with and without the
  argument, and a class field with a tuple default.

## Implementation plan

- `compiler/types.lua`: tuples in `comparable`; add `ordered` and `items`.
- `compiler/check.lua`: ordering via `types.ordered`; tuple iteration in `For`;
  `copy_default` in `bind_args`.
- `compiler/lower.lua`: tuple `==`/`!=` and ordering; `list_contains_converted`;
  convert the iterable of a tuple `for`; update the `lower_args` comment.
- `compiler/parser.lua`: tuple defaults; `compiler/bind.lua`: `default_type`.
- `runtime/core.lua`: tuples in `__wlo_equal`; `__wlo_tuple_order`,
  `__wlo_tuple_items`; `__wlo_list_contains_converted` replaces
  `__wlo_list_contains_boxed`.
- Tests listed above; `agents/todo.md`: check off the task.
