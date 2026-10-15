# Lists, dictionaries, and `for`

## Goal

Add `list[T]` and `dict[K, V]`, list and dict displays, indexing and index
assignment, the §15 methods, `len`, `in` and `not in`, and `for` loops over
lists, dictionaries, and `range` (willow.md §12, §15). When done, the §15 example
checks, builds, and runs with the output in its comments; collection operations
have the §15 types and runtime messages with accurate locations; and evaluation
order matches Python.

## Related code

- `compiler/lexer.lua` — `keywords`, `operators`, and `depth`, which only counts
  parentheses.
- `compiler/parser.lua` — `parse_type`, `parse_primary`, `parse_unary`,
  `parse_comparison`, `parse_assignment_or_call`, `parse_statement`, and the
  `unsupported` reserved words (`for`, `in`).
- `compiler/bind.lua` — `builtins`, `collect_symbols`, `resolve_function`, and the
  `print` redefinition check.
- `compiler/check.lua` — `check_expression`, `builtins`, `optional`, `base`,
  `assignable`, `assigned_symbols`, and the `Assign`, `While`, and `CallStmt`
  rules.
- `compiler/lower.lua` — `is_pure`, `helper`, `lower_value`, `lower_operand`,
  and `While` lowering.
- `compiler/emit.lua` — `expr` and `While` emission.
- `runtime/core.lua` — `__wlo_fail` and the existing helpers.

## Decisions

### Types

- Types stay strings. `parse_type` builds `list[T]` and `dict[K, V]` (one space
  after the comma), so equal types are equal strings and invariance is string
  equality. Check gets `list_element(type)`, matching `^list%[(.*)%]$`, and
  `dict_types(type)`, matching `^dict%[(%a+), (.*)%]$`. Neither matches an
  optional, whose string ends in ` | None`.
- `list` and `dict` join the lexer keywords and the parser's `type_names`.
  `parse_type` reads `list [ T ]` and `dict [ K , V ]` recursively, then the
  existing `| None` suffix. A key type other than `int` or `str` is
  `dictionary keys must be int or str` at the key type.
- `scalar(type)` is true when the type, or its base if optional, is `int`,
  `float`, `bool`, `str`, or `None`. `==`, `!=`, `print`, and the element or key
  side of `in` require scalars.

### Syntax

- The lexer adds `[ ] { } .` to `operators` and tracks `depth` for all three
  bracket kinds, so newlines inside any of them produce no layout tokens.
- `parse_primary` adds `ListDisplay { elements }` for `[...]` and
  `DictDisplay { entries = { { key, value }, ... } }` for `{...}`, both allowing a
  trailing comma.
- A new `parse_postfix` follows a primary: `[ expr ]` builds
  `Index { object, index }` with the `[` token's span; `. NAME (args)` builds
  `MethodCall { object, name, args }` with the name token's span. `. NAME`
  without `(` is `methods must be called`. A `(` after any postfix expression or
  primary other than a bare name is the existing
  `call target must be a function name`. `parse_unary` calls `parse_postfix`.
- `parse_comparison` accepts `in` and `not in` (a `not` token followed by `in`)
  as `Binary` ops `in` and `not in`; chains stay rejected.
- `parse_assignment_or_call`: `Index = value` builds
  `IndexAssign { object, index, value }` with the `Index` span; `:` after a
  non-name is `only a name can have an annotation`; `MethodCall` joins `Call` as
  a valid expression statement.
- `parse_statement` parses `for NAME in expression:` into
  `For { name, iterable, body }` with the `for` token's span. `for` and `in` leave
  the parser's unsupported reserved words.

### Binding

- `builtins` gains `len` and `range`. Any file-level function whose name is a
  built-in is `cannot redefine built-in function '<name>'`.
- `collect_symbols` treats a `For` name like an assignment target and walks its
  body; `For.symbol` is set in `resolve_function`. Resolution walks `Index`,
  `MethodCall` objects and arguments, display elements and entries,
  `IndexAssign`, and `For` iterables and bodies.

### Checking

- `check_expression(node, state, expected)` gains an optional expected type.
  Callers pass it where §15 says a display takes one: an annotation or a local's
  existing type in `Assign`, a parameter type in calls, the return type in
  `Return`, the element or value type in `IndexAssign` and `append`, and the
  element, key, or value type inside an enclosing display. Only displays read
  it.
- A display's expected type is unwrapped from an optional first. A `list[T]` (or
  `dict[K, V]`) expectation checks each element (key, value) with `expect_type`
  against `T` (`K`, `V`) and gives the display that type. Otherwise a non-empty
  display takes `list[T]` from its first element (or `dict[K, V]` from its first
  entry, with `K` required to be `int` or `str`) and checks later ones against
  it; an empty display is `cannot infer the element type of an empty list` or
  `cannot infer the key and value types of an empty dict`.
- `Index`: on `list[T]` the index must be `int` and the result is `T`; on
  `dict[K, V]` the key must be assignable to `K` and the result is `V`; anything
  else is `cannot index a value of type <type>`.
- `MethodCall` on `list[T]`: `append(v: T) -> None`, `pop() -> T`. On
  `dict[K, V]`: `get(k: K)` returns `V` when `V` is `None` or optional and
  `V | None` otherwise; `pop(k: K) -> V`. Wrong counts reuse the
  `'<name>' expects N arguments` message; anything else is
  `type <type> has no method '<name>'`.
- `len(x)` needs a list or dict: `'len' cannot be applied to <type>`.
  A `range` call reached through `check_expression` is
  `'range' can only be used as a 'for' iterable`.
- `in` and `not in`: on `list[T]` the left operand and `T` must be scalars that
  `==` accepts; on `dict[K, V]` the left operand must be comparable with `K`;
  otherwise the usual `operator 'in' cannot be applied to A and B`.
- `==` and `!=` additionally require both operands to be scalars. `print`
  rejects a non-scalar argument with `cannot print a value of type <type>`.
- `For`: a `range` call takes one to three `int` arguments
  (`'range' expects 1 to 3 arguments, received N`) and yields `int`; a list yields
  `T`; a dict yields `K`; anything else is `cannot iterate over <type>`. The loop
  name follows the assignment rules: the item type fixes the local's type on its
  lexically first assignment and must otherwise be assignable to it. The loop is
  checked like `while`: `assigned_symbols` includes `For` names, narrowing is
  reset for every symbol the body or loop name assigns, the body starts from that
  state with the loop name assigned (narrowed as an assignment would), and the
  reset state is the state after the loop, so the loop name is not definitely
  assigned afterwards. `break` and `continue` are allowed in the body.
- Index and method-call operands of `is` yield no facts, which the existing
  `Name`-only rule already gives.

### Lowering and emission

- Lists are runtime tables with an explicit length `n`; dictionaries hold
  `keys` (an array in insertion order), `positions` (key to array index),
  `values`, and `version`, which changes when a key is added or removed. The
  emitter only calls runtime helpers, so this layout stays inside
  `runtime/core.lua`.
- Displays lower to new expressions `List { elements }` and
  `Dict { entries }` (keys and values flattened in order). Each element, key, and
  value is lowered with `lower_operand` in source order, so calls run left to
  right, key before value. They emit `__wlo_list({ a, b }, 2)` and
  `__wlo_dict({ k1, v1, k2, v2 }, 2)`; the explicit count keeps stored `nil`s.
  `is_pure` treats a display as pure when its parts are.
- Helper calls, all impure because a later call can change a collection:
  `list_index`, `dict_index`, `list_set`, `dict_set`, `list_append`, `list_pop`,
  `dict_get`, `dict_pop`, `list_contains`, `dict_contains`, and `len`. The helper
  is chosen from the operand's checked type.
- `not in` spills the `contains` helper into a temporary before wrapping it in
  `Not`, so it is evaluated in order. `lower_operand`'s temporary step becomes a
  `spill(value, mark)` function that both use.
- `IndexAssign` lowers the value, then the object, then the index with
  `lower_operand`, and emits an `Eval` of `list_set` or `dict_set` with the `Index`
  span.
- `For` lowers to `{ kind = "For", target, iterator, body, label, continues }`.
  The iterator is a helper call built after the iterable is lowered:
  `range(start, stop, step)` with defaults `0` and `1` and the `range` call's
  span, `list_items(list)`, or `dict_items(dict)` with the `for` span. Emission:

  ```lua
  for _, __wlo_item in __wlo_list_items(xs, 4) do
    word = __wlo_item
    <body, wrapped in do ... end before the continue label when needed>
  end
  ```

  The generic `for` evaluates the iterator once, so later uses of the same
  temporaries in the body are safe. `While` and `For` share the body emission
  with the continue label.
- Runtime helpers:
  - `__wlo_list(items, n)`, `__wlo_dict(entries, n)` (inserting through
    `__wlo_dict_set`, so a repeated key keeps its first position and last value).
  - `__wlo_len(value)` returns `value.n or #value.keys`.
  - `__wlo_list_index`, `__wlo_list_set`: `list index out of range` unless
    `0 <= i < n`. `__wlo_list_append`. `__wlo_list_pop`: `pop from empty list`.
    `__wlo_list_contains` compares with `==` over `1..n`.
  - `__wlo_dict_index`, `__wlo_dict_pop`: `key not found`. `__wlo_dict_pop`
    removes the key from `keys` and renumbers later positions. `__wlo_dict_set`
    appends new keys and bumps `version`. `__wlo_dict_get` returns the stored
    value or `nil`. `__wlo_dict_contains` tests `positions`.
  - Iterators return `true, item`: `__wlo_list_items` rechecks `n` each step;
    `__wlo_dict_items` fails with `dictionary changed size during iteration`
    when `version` changed; `__wlo_range` fails with
    `range step must not be zero` when created and stops at `stop` with Python's
    sign rules.
  - Failure categories `index`, `key`, and `value`.

## Test plan

- `tests/unit/lexer_test.lua`: `[ ] { } .` tokens; newlines inside brackets and
  braces produce no layout tokens; the unexpected-character test uses `@`.
- `tests/unit/parser_test.lua`: `list[int]`, `dict[str, int | None]`,
  `list[int] | None`, and `dict[float, int]` rejected; displays with trailing
  commas over several lines; `rows[0].pop()` and `-xs[0]` grouping;
  `a not in b` and `not a in b`; index assignment; annotation on an index
  rejected; `xs.append` without a call, `items[0](x)`, and `xs.f(1)(2)`
  rejected; `for` statements.
- `tests/unit/bind_test.lua`: redefining `len` or `range`; a `for` name is a
  local that shadows a function; calling `range` when a local shadows it.
- `tests/unit/check_test.lua`: display inference, mixed elements, empty displays
  with and without an expected type (annotation, parameter, return, nested,
  `append`), invariance between `list[int]` and `list[int | None]`, dictionary
  key types; index, method, `len`, and `in` types and errors, including `get` on
  optional values and `in` on a list of lists; `==` and `print` on collections;
  `for` item types, loop name fixed by the loop, mismatched loop name type,
  `range` arity and argument types, `range` outside `for`, loop name not
  definitely assigned after the loop, `break`/`continue` in `for`; an index
  expression that does not narrow.
- `tests/unit/lower_test.lua`: display element order; index assignment order
  (value, object, index); `not in` spilled to a temporary; the `For` shape.
- `tests/programs/collections.wlo` with `.out`: the §15 example; stored `None`
  in lists and dicts; `get` on missing and stored `None`; dictionary order after
  replace, `pop`, and reinsert; repeated display keys; iteration while
  appending; replacing values while iterating; loop name keeping its last value;
  `range` with one, two, and three arguments including negative steps and empty
  ranges; aliasing through assignment and arguments; display and index
  assignment evaluation order made visible with printing functions. Expected
  output comes from running the program in Python.
- Program tests with `.err` for each runtime failure, each raised inside a
  called function so a caller frame shows: `list_index_out_of_range.wlo`
  (negative index), `key_not_found.wlo`, `pop_from_empty_list.wlo`,
  `dictionary_changed_size.wlo`, and `range_zero_step.wlo`.

## Implementation plan

1. `compiler/lexer.lua`: keywords `list dict`; `[ ] { } .`; bracket depth.
2. `compiler/parser.lua`: collection types, displays, `parse_postfix`, `in` and
   `not in`, `IndexAssign`, method-call statements, `For`.
3. `compiler/bind.lua`: `len` and `range`, the redefinition check, `For`
   symbols, and resolution of the new nodes.
4. `compiler/check.lua`: type helpers, the expected-type argument, displays,
   `Index`, `MethodCall`, `len`, `range`, `in`, scalar checks, `IndexAssign`, and
   `For`.
5. `compiler/lower.lua`: `spill`, displays, helpers, `IndexAssign`, `For`.
6. `compiler/emit.lua`: `List`, `Dict`, and `For`, with the shared loop body.
7. `runtime/core.lua`: the collection helpers and iterators.
8. Tests as listed above.
9. `examples/collections.wlo`: word counting with a dict, a list built with
   `append`, and a `range` loop; check, build, and run it.
10. `agents/todo.md`: tick the milestone.
