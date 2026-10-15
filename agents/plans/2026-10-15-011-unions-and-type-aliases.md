# Unions and type aliases

## Goal

Add general unions, `type` aliases (including recursive ones), and `isinstance`
(docs/spec.md §3, §4, §9). When done, unions of any members in any order check
and run; aliases are the same type as their expansions; `isinstance`,
`is None`, and `is not None` narrow a local to a set of members; a union holding
`1` differs from one holding `1.0`; and JSON-shaped recursive values can be
built from displays and walked.

## Related code

- `compiler/parser.lua` — `parse_type` builds `Type` nodes whose `name` is a
  type string and whose `records` lists the names bind resolves; `UNIONS`
  rejects unions other than `T | None`; `type` is in `unsupported`; the file
  loop accepts only `def` and `class`.
- `compiler/bind.lua` — `builtins`, `exceptions`, `lookup`, `resolve_record`,
  `resolve_type` (rewrites type strings), `resolve_function`, `declare`, and the
  `main` signature check.
- `compiler/check.lua` — every type is a string: `assignable`, `optional`,
  `base`, `scalar`, `list_element`, `dict_types`, `method_signature`, the flow
  state, facts, `join`, `assign`, displays, and the `records` and
  `exception_classes` maps.
- `compiler/lower.lua` — `prefix`, `is_float`, `binary_helper`, and the
  `node.type == "..."` tests; `lower_value` and `lower_operand`.
- `compiler/emit.lua` — `Construct` writes `__wlo_class` only for exceptions;
  `For` writes `target = __wlo_item`.
- `runtime/core.lua` — `__wlo_str`, `__wlo_str_float`, `__wlo_list_contains`.
- `tests/unit/*_test.lua` compare `node.type` and `Type.name` with strings.

## Decisions

- **Type objects.** Types become tables in a new `compiler/types.lua`, because
  string types cannot express unordered unions or recursive aliases. Every type
  has `kind` and a display `name`:
  - Singletons `types.int`, `types.float`, `types.bool`, `types.str`,
    `types.None` with `kind` equal to their name.
  - `types.list(element)`, `types.dict(key, value)`.
  - `types.record(decl)`: `{ kind = "record", record = decl }`, created once per
    record as `decl.type`, named by `decl.type_name`.
  - `types.union(members, name)`: `{ kind = "union", members }`. It flattens
    union members, returns the only member when one is left, and names itself
    by joining member names with ` | ` unless given `name`. It does not
    validate.
  - Lazy types: `{ kind = "lazy", name, type }`, created by bind for every
    `list[...]` element and `dict[...]` value written in source, with `type`
    filled in later. `types.expand(t)` returns `t.type` for a lazy type and `t`
    otherwise. Anything that opens a list or dict (`element`, `value`) expands.
    Everything else is never lazy.
  Scalars and records compare by identity. `types.same(a, b)` expands both,
  compares kinds, elements, keys, and values, and matches union members by key
  (`kind`, or the record for records) regardless of order. It keeps a set of
  pairs already assumed equal so that two distinct but structurally equal
  recursive aliases terminate.
- **Type helpers in `types.lua`.** `members(t)` (the members of a union, or
  `{ t }`), `has(t, kind)`, `optional(t)` (a union with a `None` member),
  `printable(t)` (every member scalar), `boxed(t)` (has both `int` and `float`
  members), `assignable(target, source)` (source union: every member assignable;
  target union: assignable to some member; otherwise `same`, or `Exception`
  record target with an exception record source), `subset(t, keep)` (the union
  of the members of `t` that `keep` accepts, `t` itself when it keeps all), and
  `conflict(members, m)` (the message for adding member `m`, or nil).
- **Union validation.** `conflict` reports `a union can have only one list
  member` (or `dict member`) first, then `union members A and B overlap` when
  either is assignable to the other, which covers `int | int`,
  `Exception | ParseError`, and `int | None | None`. Checking list and dict
  counts first means validation never compares element types, so it never
  expands a lazy type.
- **Type syntax.** `parse_type` reads members separated by `|`. A member is a
  `Type` node `{ name, module, args }`: `name` is a type keyword (`int`, `float`,
  `bool`, `str`, `None`, `list`, `dict`) or an identifier, `module` is set for
  `module.Name`, and `args` holds the `list` element or the `dict` key and
  value. Two or more members make a `UnionType` node `{ members }`. Type names
  are reserved, so `name` alone tells keywords from declarations. The dict key
  rule moves to bind so that an alias of `str` can be a key.
- **Alias declarations.** `type Name = Type` at file scope parses to
  `Alias { name, value }` in a new `program.aliases`, with the span of the name.
  `type` leaves `unsupported`. The file-scope error becomes `only function,
  class, and type declarations are allowed at file scope`.
- **Resolution.** Bind replaces each annotation (`param.type`,
  `fn.return_type`, `field.type`, `statement.annotation`) with a type object.
  `resolve_named(ref, module)` (renamed from `resolve_record`) returns a record
  or alias declaration. `resolve_type(node, module)` resolves keywords to
  singletons, records to `decl.type`, aliases to their expansion through
  `resolve_alias`, unions by flattening each member and calling `conflict` at
  the member's span, dict keys eagerly with `dictionary keys must be int or str`,
  and list elements and dict values to lazy types queued in `pending`. A lazy
  type's `name` comes from `type_text(node, module)`, which writes the source
  type with declarations replaced by their `type_name`.
- **Recursive aliases.** `resolve_alias(decl)` sets `decl.resolving` while it
  resolves `decl.value` into `decl.type`. Reaching an alias that is resolving
  is `alias 'Loop' expands to itself` at the reference. Since list elements and
  dict values are lazy, `list[Json]`, `dict[str, Json]`, and
  `list[str | Json]` never reach this check, and `int | Loop` and
  `type A = B` / `type B = A` do. A union written as an alias's value is named
  by the alias's `type_name`, so messages read `expected Json, ...`.
- **Bind order.** Declare; resolve every alias; resolve record fields and
  function signatures; force `pending` (forcing may queue more); check `main`
  with `types.same`; resolve bodies; force `pending` again. Aliases get
  `type_name` like records. `lookup`'s message becomes
  `module 'm' has no function, record, or alias 'x'`.
- **Alias misuse.** A `Name` naming an alias is
  `alias 'X' cannot be used as a value`; a call to an alias, bare or
  module-qualified, is `alias 'X' cannot be called`. An alias in `except`
  already fails as `'X' is not an exception class`.
- **`isinstance`.** `isinstance` joins bind's `builtins`. The parser turns
  `isinstance(` into `IsInstance { operand, class }`, where `class` is
  `{ name, module, span }` from a type keyword other than `None` or a possibly
  qualified name, else `expected a class name`; an optional trailing comma is
  allowed. Bind rejects it as a call to a local when a local shadows
  `isinstance`, resolves a named class to `class.record`, and rejects aliases
  with `alias 'X' cannot be used in isinstance`. Check finds the member of the
  operand's current type that the class names (the singleton, the `list` or
  `dict` member, or `record.type`), else `type T has no member C`, stores it as
  `node.member`, and yields `bool`. For a `Name` operand of union type, the true
  facts narrow to `node.member` and the false facts to the other members.
- **Narrowing.** The flow state still maps symbols to types, now type objects
  built only from the declared type's member objects, so membership is by
  identity.
  - `is not None` true facts and `is None` false facts are
    `subset(current, m ~= types.None)`.
  - `join` keeps a symbol's type when both sides agree and otherwise takes
    `subset(symbol.type, m in either side)`.
  - `assign`: when the local's type is a union and the value's type is one
    non-`None`, non-union type, the local narrows to the member the value is
    assignable to; otherwise it takes its declared type. This keeps today's
    `Exception | None` behavior.
  - Loops and `try` keep their current forgetting rules.
- **Checker changes.** Operator tables are keyed by `kind`, so a union operand
  fails as today's optionals do. `==`, `!=`, `in`, `print`, `eprint`, `str`, and
  f-string fields use `printable`. Displays take the expected type's list or dict
  member (`expected` itself or its member of that kind), and a display checked
  against such a member has that member object as its type. `dict.get` returns
  `V` when `V` is `None` or optional, else `types.union({ V, types.None })`.
  `input` returns `str | None` the same way. The `records` and
  `exception_classes` maps go away in favor of `record.type` and
  `type.record.exception`. A `For` node's `type` is its item type.
- **Runtime representation.** Union values are untagged except where Lua
  cannot tell members apart:
  - In a type where `boxed` is true, a float is the table
    `{ __wlo_float = x }` and an int stays a number. Elsewhere, including
    `float | None`, floats stay numbers, so current optional code is unchanged.
  - Every record carries its class: exceptions keep `__wlo_class`, and other
    records get `__wlo_record = type_name`, so `isinstance(e, Exception)` can
    test for `__wlo_class` alone. Lists are told from dicts by `n`.
- **Conversions.** `expect_type` records `node.expected_type` on the node it
  checks, which covers initializers, assignments, arguments, constructor
  arguments, returns, display elements, field and index assignment, `append`,
  and the `For` item. `convert(value, from, to)` in lower wraps `value` in
  `__wlo_box` when `to` is boxed and `from` is not but has a `float` member, in
  `__wlo_unbox` for the reverse, and otherwise returns it. It runs:
  - In `lower_value` on the result, and in `lower_operand` after spilling, so a
    box never hides a call inside an operand. The current `lower_value` body
    becomes `lower_node`.
  - On a `Name` read from `symbol.type` to the narrowed `node.type`.
  - On both `==`/`!=` operands toward the boxed operand's type when either is
    boxed, which then lower to `__wlo_equal`.
  - On the left of `in` toward a list's element type. When the left is boxed
    and the elements are unboxed floats, `in` uses `list_contains_boxed`.
  - On the `For` item toward the loop name's type.
- **Lowered nodes.** A new `Pure { name, args }` is a runtime call that cannot
  fail, emitted inline as `__wlo_<name>(args)` without a site and never spilled.
  It carries the span of its first argument so a statement still maps to the
  call it wraps. Box, unbox, equality, and `isinstance` use it. `isinstance`
  passes a kind string: `number` for `int` and for `float` in an unboxed type,
  `box` for `float` in a boxed type, `boolean`, `string`, `list`, `dict`,
  `Exception`, or the record's `type_name`. `Construct` carries `class` and
  `exception`, and emit writes `__wlo_class` or `__wlo_record`. A lowered `For`
  gets `value`, an `Item` expression (`__wlo_item`) possibly converted, which
  emit assigns to the target.
- **Formatting.** `is_float(type)` in lower means "has a `float` member and no
  `int` member". `__wlo_str` formats a box as a float, and `__wlo_str_float`
  formats numbers as floats and hands everything else to `__wlo_str`, so
  `float | str` prints correctly.

## Test plan

- `tests/unit/parser_test.lua`: a `show_type` helper replaces `type.name`;
  `type` declarations; unions in any order including `None | int` and
  `int | str | list[int]`; `module.Alias` in annotations; `isinstance` with
  keyword, named, and qualified classes; `isinstance(x, None)`,
  `isinstance(x)`, and `type` inside a function rejected; the new file-scope
  message.
- `tests/unit/bind_test.lua`: aliases sharing the namespace (duplicate with a
  function, built-in names, `def isinstance`); forward, self, and cross-module
  references; a private `_` alias from another module; a local shadowing an
  alias while annotations still name it; alias as a value, call, and
  `isinstance` class rejected; `int | Loop` and mutual aliases rejected while
  `list[T]`, `dict[str, T]`, and `list[str | T]` are accepted; `int | int`,
  `Exception | ParseError`, `list[int] | list[str]`, and `N | None` with
  `type N = int | None` rejected; `dict[float, int]` rejected and an alias of
  `str` accepted as a key; the updated `lookup` message.
- `tests/unit/check_test.lua`: string type assertions compare `.name`;
  `list[Json]` assignable both ways to `list[` its written expansion `]`;
  `list[int | str]` and `list[str | int]` interchangeable; union widening and
  narrowing assignments; `list[int]` not assignable to `list[int | str]`;
  `==` on unions with an assignable and a non-assignable operand; printing a
  union with a list member rejected; `x: int | list[int] = []` and a dict
  display against `dict[str, int] | None`; `isinstance` with a non-member
  class; narrowing through `if`/`elif`/`else`, `and`, `or`, `not`, assignment
  of one member, and other assignments; a three-member union joined after an
  `if`; narrowing cleared by a loop assignment and kept into a `try` clause when
  the body does not assign the local.
- `tests/unit/lower_test.lua`: `show_expr` learns `Pure`; assigning a float to
  an `int | float` local boxes it; a narrowed read unboxes it; `==` on
  `int | float` uses `equal`; `isinstance` passes the expected kind string; the
  existing `in` expectations still hold.
- `tests/programs/unions.wlo` with `.out`: the §4 `describe` example; `int` and
  `float` members printed through `print`, `str`, and f-strings, including
  `1.0`, `-0.0`, and `nan`; `==` across and within members; `in` on
  `list[int | float]` and an `int | float` value in a `list[float]`; records of
  two classes told apart by `isinstance`; a recursive `Json` value built from
  displays and rendered by a recursive function. Expected output comes from
  running the same program in Python 3.12.
- `tests/modules/unions/` (`main.wlo`, `shapes.wlo`, `main.out`): an alias of
  two records declared in `shapes` and used as `shapes.Shape` in `main`, with
  `isinstance(s, shapes.Circle)` narrowing to call a field.

## Implementation plan

1. `compiler/types.lua`: singletons, constructors, `expand`, `members`, `has`,
   `optional`, `printable`, `boxed`, `same`, `assignable`, `subset`,
   `conflict`.
2. `compiler/parser.lua`: member and union type parsing without `UNIONS`;
   `Alias` declarations and `program.aliases`; `IsInstance`; `type` out of
   `unsupported`; the file-scope message.
3. `compiler/bind.lua`: `isinstance` built-in; exception records with
   `types.str` fields and `decl.type`; aliases in `declare`; `resolve_named`,
   `type_text`, `resolve_type`, `resolve_alias`, lazy forcing; alias misuse
   errors; `IsInstance` resolution; the bind order and `main` check.
4. `compiler/check.lua`: type objects throughout; `expected_type` in
   `expect_type`; `IsInstance` typing and facts; generalized `Is` facts, `join`,
   and `assign`; displays against union members; `For` item type.
5. `compiler/lower.lua`: `lower_node`, `convert`, `Pure`; type tests by object;
   `==`, `in`, `isinstance`, `Construct`, and `For` changes.
6. `compiler/emit.lua`: `Pure`, `Item`, the record tag, and the `For` value.
7. `runtime/core.lua`: `__wlo_box`, `__wlo_unbox`, `__wlo_equal`,
   `__wlo_isinstance`, `__wlo_list_contains` through `__wlo_equal`,
   `__wlo_list_contains_boxed`, and the `__wlo_str` and `__wlo_str_float`
   changes.
8. Tests as listed above.
9. `agents/todo.md`: tick the sixth slice.
