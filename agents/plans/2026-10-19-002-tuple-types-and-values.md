# Tuple types and values

## Goal

Start the tuple milestone in `agents/todo.md` (spec §3 Annotations, §4, §7
Tuples and unpacking). `tuple` is reserved; `tuple[A, B]` and `tuple[()]`
annotate tuples; `()`, `(x,)`, and `(x, y)` build them while `(x)` stays
grouping; literal and negated-literal indexes read positions, with
out-of-range indexes rejected at compile time; `len` gives the arity; a tuple
is assignable to a tuple type of the same length position by position, with
floats boxed or unboxed per position at run time; a union holds at most one
tuple member; and `isinstance(v, tuple)` tests it. Equality, ordering,
iteration, defaults, and unpacking are later tasks.

## Related code

- `compiler/lexer.lua` `keywords` and `compiler/parser.lua` `type_names` — reserved type names; `type_names` also admits them in `isinstance`.
- `compiler/parser.lua` `parse_member` (types) and `parse_primary` (`(` grouping).
- `compiler/bind.lua` `resolve_type` — builds `list` and `dict` types.
- `compiler/types.lua` — `same`, `assignable`, `conflict`; type objects by kind.
- `compiler/check.lua` — `display_member`, `ListDisplay`, `Index`, `Slice`, `len` in `Call`, `IsInstance`, and `IndexAssign`.
- `compiler/lower.lua` `convert` — boxes or unboxes floats where the static types' representations differ; `instance_kind` gives the `isinstance` kind string; `lower_object` returns a local or temporary to read from.
- `compiler/emit.lua` `expr` — renders lowered expressions.
- `runtime/core.lua` `__wlo_box`, `__wlo_unbox`, `__wlo_isinstance`.

## Decisions

- Runtime representation: a tuple is a Lua table `{ __wlo_tuple = n, e1, ..., en }`,
  where `n` is the arity. Positions may hold `nil` for `None`, which is safe
  because every index is known at compile time. `__wlo_isinstance` tests
  `__wlo_tuple` before the list and dict tests, so a tuple is never taken for
  a dict.
- Types: `types.tuple(elements)` returns `{ kind = "tuple", elements, name }`,
  named `tuple[int, str]` or `tuple[()]`. Positions resolve eagerly in bind,
  since alias recursion is only allowed inside `list` and `dict`.
  `same` compares tuples position by position. `assignable` accepts a tuple
  source for a tuple target of the same arity when every position is
  assignable. `conflict` counts tuples with lists and dicts, reporting
  "a union can have only one tuple member".
- Displays: `TupleDisplay` nodes. With an expected tuple member of the same
  arity (found by `display_member(expected, "tuple")`), each element is checked
  against its position and the display takes that type, so a display never
  needs conversion. Otherwise the display's type is inferred from its elements.
- Indexing: the index must be an `Int` or a `Unary` `-` on an `Int`; anything
  else reports "tuple index must be an integer literal". A negative index adds
  the arity; an index outside the tuple reports "tuple index out of range".
  Check stores the one-based Lua position in `node.position`. Lowering reads
  `lower_object(node.object)` with a new lowered `Position` node that emits
  `object[position]`; it needs no helper or site because it cannot fail.
- `len` of a tuple lowers to its arity as a literal after its argument is
  lowered, so a call in the argument still runs.
- Assigning, indexing, and slicing: `t[0] = v` reports
  "cannot assign to an index of a value of type tuple[...]" like `str` and
  `bytes`. Slicing keeps the existing "cannot slice" error.
- Per-position float conversion: a new `conversion(from, to)` in `lower.lua`
  returns nil when the representations agree, or a step table whose `float`
  entry is `"box"` or `"unbox"` and whose entry `[i]` is the step for tuple
  position `i`, recursing through the tuple members of `from` and `to`.
  `convert` keeps emitting `box` and `unbox` when `from` has no tuple member,
  and otherwise emits the pure helper `convert(value, step)`. The step is a
  `Literal` whose value is a table; `emit` renders it with `float` first and
  then the positions in order as `[i] = ...`. `__wlo_convert` in
  `runtime/core.lua` copies a tuple and converts the positions its step names,
  boxes or unboxes a number by the step's `float` entry, and returns other
  values unchanged, so optional and union sources need no separate test.

## Test plan

- `tests/unit/parser_test.lua`: `tuple[int, str]` and `tuple[()]` annotations;
  `()`, `(1,)`, and `(1, 2,)` parse as `TupleDisplay` while `(1)` is an `Int`;
  `tuple` used as a name is rejected.
- `tests/unit/bind_test.lua`: a `tuple[int, str]` parameter and an alias to a
  tuple resolve with those names; `tuple[int] | tuple[str]` reports
  "a union can have only one tuple member".
- `tests/unit/check_test.lua`: `t[2]` and `t[-3]` on a pair report
  "tuple index out of range"; `t[i]` reports "tuple index must be an integer
  literal"; `t[0] = 1` and `t[0:1]` are rejected; passing a pair where
  `tuple[int]` is expected reports "expected tuple[int], received tuple[int, int]";
  a display element of the wrong type reports at the element;
  `isinstance(x, tuple)` without a tuple member is rejected; printing a tuple
  is rejected.
- `tests/programs/tuples.wlo` and `.out`: build and index tuples with positive
  and negative indexes, including nested tuples and a `None` position; `len`
  of a tuple and of a call that prints; displays evaluate left to right;
  `isinstance(v, tuple)` narrows a `tuple[int, str] | list[int] | None`; a
  `tuple[float, float]` local passed as `tuple[int | float, float]` and a
  `tuple[float] | None` returned as `tuple[int | float] | None` keep their
  values and test as floats with `isinstance`.

## Implementation plan

- `compiler/lexer.lua`, `compiler/parser.lua`: reserve `tuple`; parse tuple
  types in `parse_member` and tuple displays in `parse_primary`.
- `compiler/types.lua`: `tuple`, and tuple cases in `same`, `assignable`, and `conflict`.
- `compiler/bind.lua`: resolve `tuple` types.
- `compiler/check.lua`: `TupleDisplay`, tuple `Index`, `len`, and `IndexAssign`;
  widen `display_member`'s comment to tuples.
- `compiler/lower.lua`: lower `TupleDisplay` to `Tuple` (pure when its
  elements are, in `is_pure`), tuple `Index` to `Position`, tuple `len` to its
  arity; add `conversion` and use it in `convert`.
- `compiler/emit.lua`: emit `Tuple`, `Position`, and table `Literal`s.
- `runtime/core.lua`: `__wlo_convert`; the tuple test in `__wlo_isinstance`.
- Tests listed above.
- `agents/todo.md`: check off the task.
