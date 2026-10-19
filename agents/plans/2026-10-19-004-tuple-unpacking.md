# Tuple unpacking

## Goal

Finish the tuple milestone in `agents/todo.md` (spec §7 Tuples and unpacking,
§8). Assignment and `for` targets may be tuple patterns of names, nested with
parentheses, as in `name, count = ("Ada", 3)` and `for key, value in pairs:`.
The source type must have the pattern's tuple shape. Repeated and starred
targets are errors. The source is evaluated once, then its positions are
assigned left to right under the ordinary local-type, definite-assignment, and
narrowing rules. `fibonacci_sequence.wlo` uses tuple assignment for its step.

## Related code

- `compiler/parser.lua` `parse_assignment_or_call` (rejects `a, b =` today) and the `for` case of `parse_statement`.
- `compiler/ast.lua` `assignments` — visits the nodes that assign names; bind's `collect_symbols` and check's `assigned_symbols` use it.
- `compiler/bind.lua` `resolve_block` — gives `Assign` and `For` their `symbol`.
- `compiler/check.lua` `check_statement` `Assign` and `For`; `expect_type`; `assign`.
- `compiler/lower.lua` `lower_statement` `Assign` and `For`; `spill`; the `Position` node from tuple indexing.
- `compiler/emit.lua` `For` — writes `target = value` at the top of the loop body.

## Decisions

- Tree: a pattern is a `Name` node (a target, with `name` and `span`) or a
  `TuplePattern` node with `elements`. Assignment to a pattern is a new
  `Unpack` statement with `pattern` and `value`. A `for` loop with a pattern
  keeps kind `For` with `pattern` in place of `name`. `ast.assignments` visits
  each target of a pattern, left to right, so symbol collection, narrowing
  resets, and definite assignment work unchanged. Bind sets `target.symbol`.
- Parsing assignments: when the first expression is followed by `,`, the
  parser reads more expressions up to `=`. It turns the list into a pattern
  with `pattern_of(expression)`: `Name` stays a target, `TupleDisplay` becomes
  a `TuplePattern`, and anything else reports "cannot assign to this
  expression". A lone `TupleDisplay` before `=`, as in `(a, b) = t`, is also a
  pattern. The value is a single expression, so `a, b = b, a` stays a syntax
  error; tuples need parentheses.
- Parsing `for`: `parse_target()` reads a name, or a parenthesized list of
  targets, where `(a)` is just `a`. A top-level comma makes a `TuplePattern`.
- `*` where a target starts reports "starred targets are not supported".
  A name that appears twice in one pattern reports "duplicate target 'a'".
  Both checks are in the parser.
- Checking: `check_pattern(pattern, type, state)` requires a `tuple` type
  (a union must be narrowed first) with as many positions as the pattern. It
  reports "cannot unpack a value of type T" or
  "cannot unpack T into N targets", recursing into nested patterns. At a
  target, it applies the `Assign` rule. If the symbol already has a type, it
  calls `expect_type(target, symbol.type, position type)`; otherwise the
  position type becomes the symbol's type. Then it calls `assign`, so later
  targets see earlier ones narrowed. The value is checked without an expected
  type, so `a, b = ([], 1)` cannot infer the list's element type even when
  `a` has a declared type.
- Lowering: `Unpack` lowers its value once and always spills it into a
  temporary, since a target may be the source local itself (`t, a = t`). Then
  `unpack(pattern, value, type)` sets each target to
  `convert(Position(value, i), position type, target.expected_type)`, nesting
  `Position` for nested patterns. A `for` with a pattern has no `target`; its
  body starts with the same unpacking from `Item`, and `emit` skips the
  `target = value` line when `target` is nil.
- `fibonacci_sequence.wlo`: the step becomes
  `previous, current = (current, previous + current)`. The example also
  prints `fib_iterative(92)`, which overflows Willow's integer range and makes
  the example fail today. The largest Fibonacci number within `2^53 - 1` is
  `fib(78)`, so the comment and call change to 78 and `.out` changes to match.

## Test plan

- `tests/unit/parser_test.lua`: `a, b = t`, `(a, (b, c)) = t`, and
  `for k, (x, y) in items:` parse as patterns; `a, a = t`, `*a, b = t`,
  `a, *b = t`, `a, f() = t`, and `a, b = b, a` are rejected.
- `tests/unit/check_test.lua`: unpacking an `int`, a `list[int]`, and a
  `tuple[int, str] | None` reports "cannot unpack a value of type ...";
  a pair into three targets reports "cannot unpack tuple[int, int] into 3
  targets"; reassigning a `str` local from an `int` position reports at the
  target; a `for` over `list[int]` with a pattern is rejected.
- `tests/programs/unpacking.wlo` and `.out`: swap with
  `a, b = (b, a)`; nested patterns; the source evaluated once when it is a call
  that prints; `t, a = t` keeps the right values; a target narrowed by its
  position type (`x: int | None` assigned from an `int` position, then used as
  an `int`); a `float` position assigned to an `int | float` local, which stays
  a float; `for name, count in [("a", 1), ("b", 2)]:` and a nested `for`
  pattern; definite assignment of every target after the statement.
- `examples/rosettacode/fibonacci_sequence.wlo` against its `.out`.

## Implementation plan

- `compiler/parser.lua`: `pattern_of`, `parse_target`, and duplicate and
  starred checks; `Unpack` statements and `For` patterns.
- `compiler/ast.lua`: visit pattern targets in `assignments`.
- `compiler/bind.lua`: resolve `Unpack` values and set target symbols for
  `Unpack` and `For` patterns.
- `compiler/check.lua`: `check_pattern`; `Unpack`; patterns in `For`.
- `compiler/lower.lua`: `unpack`; `Unpack`; patterns in `For`.
- `compiler/emit.lua`: skip a `For` loop's `target` line when it has none.
- `examples/rosettacode/fibonacci_sequence.wlo` and `.out`.
- Tests listed above; `agents/todo.md`: check off the task and the milestone.
