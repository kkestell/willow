# Optional types

## Goal

Add `T | None` types, `is None` and `is not None`, assignability from `T` and
`None` to `T | None`, and flow-sensitive narrowing (willow.md §14). When done, the
§14 example checks, builds, and runs with the output in its comments; operations
other than assignment, passing, returning, comparison, printing, and `is` are
type errors on an unnarrowed optional; and narrowing follows the §14 rules
through `not`, `and`, `or`, `if`/`elif`/`else`, assignments, and `while`.

## Related code

- `compiler/lexer.lua` — `operators` and `unsupported`; `|` is unsupported today.
- `compiler/parser.lua` — `parse_type`, `parse_comparison`, `compare_ops`, and
  the `unsupported` reserved words, which include `is`.
- `compiler/check.lua` — `expect_type`, the `Binary` branch and `EQUALITY`,
  `check_statement`, `check_block`, and the `assigned` set used for definite
  assignment.
- `compiler/lower.lua` — `is_pure`, `lower_value`, and `print_float` selection.
- `runtime/core.lua` — `__wlo_print_float`.
- `tests/unit/parser_test.lua`, `tests/unit/check_test.lua`,
  `tests/unit/lower_test.lua`, `tests/programs/`.

## Decisions

- **Type representation.** Types stay strings. An optional is the string
  `"T | None"`, built by `parse_type` into the `Type` node's `name`, so error
  messages read `expected int | None, received str` without new formatting. Check
  gets two helpers: `optional(type)` tests for the ` | None` suffix and
  `base(type)` strips it.
- **Annotation syntax.** `parse_type` reads a type name and, on `|`, requires
  `None` next. `None | T`, `int | str`, and `int | None | None` all fail with
  `unions other than 'T | None' are not supported` at the offending token.
- **`|` in expressions.** `|` moves from `unsupported` to `operators` in the
  lexer (`|=` stays unsupported). The parser reports `unsupported operator '|'`
  when `|` follows a comparison operand, which is where any expression stops
  before a `|`, so bitwise or keeps its §4 error.
- **`is` syntax.** `is` leaves the parser's unsupported reserved words.
  `parse_comparison` accepts `is` or `is not` followed by the `None` token and
  builds an `Is` node `{ op = "is" | "is not", operand }` whose span is the `is`
  token. Anything else after `is` is `expected 'None'`. A further comparison
  operator or `is` after it is the existing chain error.
- **Assignability.** `assignable(target, source)` is
  `target == source or optional(target) and (source == "None" or source == base(target))`.
  `expect_type` uses it, so arguments, returns, built-in parameters, conditions,
  annotated initializers, and later assignments all accept widening, and nothing
  else changes. The first-assignment rule already fixes a local's type; later
  assignments now need only be assignable to it.
- **`is` typing.** The operand must be optional; otherwise
  `operator 'is' cannot be applied to int` (or `'is not'`). The result is `bool`.
- **Equality.** `==` and `!=` give `bool` when either operand type is assignable
  to the other, replacing the `EQUALITY` table. Every type so far is a scalar or an
  optional scalar, so no other restriction is needed yet.
- **Flow state.** The `assigned` set becomes `state`: a map from each definitely
  assigned symbol to its type at that point, which is `base(symbol.type)` where
  narrowed and `symbol.type` otherwise. A `Name` takes its type from `state`, and a
  missing entry is the existing use-before-assignment error. One map keeps
  definite assignment and narrowing under the same join, and narrowing a symbol
  that is not assigned cannot happen because the check reads it first.
- **Joins.** `join(a, b)` keeps the symbols in both maps; a symbol keeps its type
  when the two agree and falls back to `symbol.type` otherwise. After an `if`, the
  state is the join of the branches that fall through, where a missing `else` is
  the entry state with the condition's false facts. `check_statement` keeps
  mutating the state it is given and returning whether it transfers; a
  `replace(state, result)` helper installs the joined result.
- **Facts.** `check_expression(node, state)` returns
  `type, true_facts, false_facts`, where facts map symbols to narrowed types and
  `NO_FACTS` is a shared empty table. `narrow(state, facts)` returns a copy of
  `state` with the facts applied.
  - `name is not None` gives true facts `{ [symbol] = base(type) }`; `name is None`
    gives the same as false facts. Only a `Name` operand yields facts.
  - `not C` swaps the facts of `C`.
  - `A and B` checks `B` in `narrow(state, true facts of A)`; its true facts are
    the union of both operands' true facts, and it has no false facts.
  - `A or B` checks `B` in `narrow(state, false facts of A)`; its false facts are
    the union of both operands' false facts, and it has no true facts.
  - Every other expression has no facts.
- **Statements.**
  - `if`: the body starts from `narrow(state, true_facts)` and the `else` (or
    implicit empty branch) from `narrow(state, false_facts)`. An `elif` is
    already a nested `If` in the `else_body`, so it inherits the earlier false
    facts.
  - Assignment: `state[symbol]` becomes the value type when it is neither `None`
    nor optional, and `symbol.type` otherwise. For a non-optional local these are
    the same type.
  - `while`: a helper `assigned_symbols(body)` collects the symbols of every
    `Assign` in the body, including nested blocks. Before the condition, each of
    those symbols present in `state` is reset to `symbol.type`. The condition is
    checked in that reset state, the body starts from it narrowed by the
    condition's true facts, and the reset state is the state after the loop.
- **Lowering.** `Is` lowers to `Binary` with `==` or `!=` against a `nil`
  `Literal`, and `is_pure` treats it as pure when its operand is. `print` uses
  `print_float` when the argument type is `float` or `float | None`, and
  `__wlo_print_float` writes `None` for `nil`. Widening needs no code.
- **Scope of tests.** Field and index expressions arrive with §15 and §16, so the
  tests showing that they do not narrow belong to those milestones.

## Test plan

- `tests/unit/lexer_test.lua`: `|` lexes as an operator; the unsupported list
  drops `|` and keeps `|=`.
- `tests/unit/parser_test.lua`: `int | None` as parameter, return, and local
  annotations; `None | int`, `int | str`, and `int | None | None` rejected;
  `x is None` and `x is not None` parse at the comparison level, so
  `not x is None` is `not (x is None)`; `x is 3` and `x is None == y` rejected;
  `a | b` in an expression is `unsupported operator '|'`.
- `tests/unit/check_test.lua`:
  - Assignability: `T` and `None` passed, returned, and assigned to `T | None`;
    `T | None` to `T`, `str` to `int | None`, and `int | None` to
    `float | None` rejected.
  - Reassignment: `x: int | None = None` then `x = 3` is valid; `x = None` then
    `x = 3` is an error; `x = 1` then `x = None` is an error.
  - `is` on a non-optional and on `None` rejected; `==` between `int | None`
    and `int` or `None` valid, and with `str` rejected; `+`, ordering, `not`, and
    conditions on an unnarrowed optional rejected.
  - Narrowing: after an early return; in `elif` and `else` from earlier
    conditions; through `and`, `or`, and `not`; after an `if` only when every
    falling-through branch narrows; an implicit `else`; ended by assigning
    `None` or an optional; started by assigning a non-optional; inside a
    `while` body from its condition; cleared at the start of and after a loop
    whose body assigns the local, and kept when the body does not.
- `tests/unit/lower_test.lua`: `x is None` lowers to `(x == None)` and
  `x is not None` to `(x != None)` inline.
- `tests/programs/optionals.wlo` with `.out`: the §14 example; printing
  `int | None`, `float | None`, `str | None`, and `bool | None` holding values and
  `None`; equality between optionals and values; `is` results in both
  directions; a loop that narrows through `while x is not None`. Expected output
  comes from running the program in Python.

## Implementation plan

1. `compiler/lexer.lua`: `|` to `operators`, out of `unsupported`.
2. `compiler/parser.lua`: optional types in `parse_type`; `is` out of
   `unsupported`; `Is` nodes, the chain check, and the `|` error in
   `parse_comparison`.
3. `compiler/check.lua`: `optional`, `base`, `assignable`, `expect_type`;
   `Is` and equality typing; `state`, `NO_FACTS`, `narrow`, `join`, `replace`,
   and `assigned_symbols`; facts from `check_expression`; the `if`, assignment,
   and `while` rules.
4. `compiler/lower.lua`: `Is` lowering, `is_pure`, and `print_float` for
   `float | None`.
5. `runtime/core.lua`: `__wlo_print_float` writes `None` for `nil`.
6. Tests as listed above.
7. `agents/todo.md`: tick the "Optional types" milestone, noting that the field
   and index narrowing tests move to §15 and §16.
