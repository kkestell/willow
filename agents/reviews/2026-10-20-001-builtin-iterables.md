# Built-in iterables, range values, and file iteration review

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-20-001-builtin-iterables.md`: the built-in `iter`
signatures and protocol satisfaction in `compiler/types.lua`, `types.iterator`,
`io.File.iter`, and the dispatch-only run-time types in `compiler/stdlib.lua`,
`range` checking in `compiler/check.lua`, the tuple conversion, `range` values,
and dispatch candidates in `compiler/lower.lua`, `__wlo_tag` in
`compiler/emit.lua`, the iterator helpers in `runtime/core.lua` and
`runtime/io.lua`, the two converted examples, and the new tests. Traced tuple
values into protocol, bounded type parameter, nested protocol, and callable
positions; dispatch tags against user class names; union rules and `isinstance`
narrowing with the newly satisfiable protocols; and file iteration after reads
and close. Compared the behavior with spec §3, §4, §8, and §14.

Gaps:

- The float-representation restriction on protocol satisfaction (`list[float]`
  is not `Iterable[int | float]`) was out of scope and left as is.

## Summary

| ID | Severity | Category    | Fix   | Title                                                                  |
| -- | -------- | ----------- | ----- | ---------------------------------------------------------------------- |
| F1 | High     | Correctness | Fixed | Tuples converted to a protocol keep their position representations     |
| F2 | Medium   | Correctness | Fixed | Tuples reach protocols uncopied through type parameters and items      |
| F3 | Medium   | Correctness | Fixed | A class named `iterator` collides with the built-in iterator's tag     |
| F4 | Medium   | Correctness | Fixed | Unions with `iter`-only protocols narrow unsoundly                     |

## F1. Tuples converted to a protocol keep their position representations

High · Correctness · Fixed · `compiler/lower.lua:123`

`conversion` computed the target for a tuple serving a protocol as
`member(to, "protocol") and member(from, "tuple")`, which is the source tuple
itself, so the `items_tuple` branch never ran and no copy was made. A
`tuple[int, float]` passed as `Iterable[int | float]` yielded an unboxed float
where `int | float` expects a boxed one: `isinstance(x, float)` was `False` for
`2.5`. Only `xs.iter()` on a tuple, which converts separately, behaved, and the
tests covered that path and int-only tuples.

### Evidence

`show((1, 2.5))` with `def show(xs: Iterable[int | float])` printing
`isinstance(x, float)` per item printed `False` twice. The compiled Lua passed
the tuple literal unconverted.

### Fix

`conversion` uses `items_tuple(source)` as the target when `to` has a protocol
member and no tuple member. `builtin_iteration.wlo` passes `(1, 2.5)` as
`Iterable[int | float]` and prints `False`, `True`.

## F2. Tuples reach protocols uncopied through type parameters and items

Medium · Correctness · Fixed · `compiler/types.lua:378`, `compiler/types.lua:609`

The copy happens only where a tuple is converted to a protocol type. A tuple
bound to `T: Iterable[int | float]` reaches `tuple_iter` through dispatch
unconverted, and a `list[tuple[int, float]]` accepted as
`Iterable[Iterable[int | float]]` yields its tuples uncopied. Both printed
`False` for `isinstance(2.5, float)`. `types.converts` did not count the copy,
so neither the bound check nor protocol compatibility rejected these cases.

### Fix

Decision: reject these cases, matching the existing rule that a converter
cannot change a float's representation at a generic or between-protocol
position. `types.converts` reports a tuple and a protocol as converting when a
position's representation differs from the item type's, and `unsatisfied`
rejects a type argument that would need converting to its bound. Both cases now
report errors; `check_test.lua` covers them.

## F3. A class named `iterator` collides with the built-in iterator's tag

Medium · Correctness · Fixed · `compiler/stdlib.lua:446`, `runtime/core.lua:914`

Built-in iterators carried `__wlo_record = "iterator"`, and the dispatch-only
type used the same tag. An entry-module class named `iterator` has the same
tag, so its dispatch entry was replaced: `sum_all(iterator(2))` iterated
nothing, and `isinstance(x, iterator)` was `True` for a built-in iterator held
in `iterator | Iterable[str]`, which then failed reading a missing field. The
other tags are reserved type or built-in function names.

### Fix

Built-in iterators use the tag `<iterator>`, which no class can have.
`dispatched` takes the tag and helper prefix separately. `builtin_iteration.wlo`
dispatches a class named `iterator` and a built-in iterator through
`Iterable[int]`.

## F4. Unions with `iter`-only protocols narrow unsoundly

Medium · Correctness · Fixed · `compiler/types.lua:544`

A `list[int]` is a valid `Iterable[int]` member value of
`list[str] | Iterable[int]`, since the union's members do not overlap by
assignability. `isinstance(x, list)` then narrows the value to `list[str]`, so
`x[0]` typed as `str` held `1`. The same holds for dicts and tuples, whose
item types the run-time test cannot see.

### Fix

Decision: reject such unions, like different specializations of one generic
class. `conflict` reports an overlap between a list, dict, or tuple member and
a protocol member that asks only for a parameterless `iter`. The union rules in
`docs/spec.md` §4 state this, and `check_test.lua` covers
`list[str] | Iterable[int]`.

## Checks run

- Focused programs for each finding before and after the fixes, including a
  callable and a protocol parameter receiving a tuple as `Iterable[int | float]`.
- `tests/unit/check_test.lua`: 60 passed.
- `willow check` on every example entry program: no type errors.
- `jsonl.wlo` on sample input: same output as before.
- `make test`: 325 passed, 0 failed.

## Verdict

The change meets the plan once fixed. F1 made the planned tuple copy a no-op,
F2 and F4 close typing gaps that the new protocol satisfaction opened, and F3
removes a dispatch tag collision.
