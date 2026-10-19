# Enum defaults and enum dictionary keys

## Goal

Finish the enum milestone in `agents/todo.md`. Parameters and fields accept
`E.MEMBER` and `module.E.MEMBER` defaults (spec §3, Functions). Dictionaries
accept one enum type as their key type, in annotations and in displays whose
key type is inferred (spec §7, Lists and dictionaries). `calc.wlo` and
`report.wlo` use enums, and a Rosetta Code "Enumerations" example is added.

## Related code

- `compiler/parser.lua` `parse_default` — parses literal defaults; rejects everything else with "a default must be a literal".
- `compiler/bind.lua` `resolve_function` — its local `enum_named` finds the enum a `Name`/`Field` chain names, and its `Field` case rewrites `E.MEMBER` into an `EnumMember` node.
- `compiler/bind.lua` `check_default` — types a default through `literal_types` and checks it against the declared type.
- `compiler/bind.lua` `resolve_type` and `compiler/check.lua` `DictDisplay` — both reject keys other than `int` and `str`.
- `compiler/check.lua` `bind_args` — fills omitted arguments with copies of `{ kind, value }` of the default.
- `compiler/lower.lua` `lower_args` and the `EnumMember` case; `compiler/emit.lua` emits `EnumMember` as a field of the enum's table.
- `runtime/core.lua` dictionaries — keyed by raw Lua values, so enum members, which are unique tables, already work as keys by identity.

## Decisions

- An enum default is parsed as a `Name` followed by one or more `.NAME`
  fields, with no call or index. A bare name is still rejected. The parser
  error becomes "a default must be a literal or an enum member".
- Bind resolves enum defaults at module scope: `enum_named` moves out of
  `resolve_function` as `enum_named(node, module, scope)`, and defaults pass an
  empty scope, since parameters and locals are not in scope for defaults. The
  member check and rewrite move into a shared `resolve_member(node, enum)`
  used by both the expression `Field` case and `check_default`.
- A dotted default whose object is not an enum reports
  "unknown enum '<path>'" at the object.
- `bind_args` copies `enum` and `name` along with `kind` and `value`, so a
  filled-in enum default is an ordinary `EnumMember` node for check, lower,
  and emit. No runtime change.
- A new `types.is_key(t)` returns true for `int`, `str`, and enum types. Bind
  and check use it, and both report "dictionary keys must be int, str, or an
  enum". A union key such as `E | F` or `E | None` is rejected by the same
  rule, which gives "one enum type per key type".
- `calc.wlo`: `enum Operator` with `ADD`, `SUBTRACT`, `MULTIPLY`, `DIVIDE`;
  `Binary.operator` becomes `Operator`, the parser maps token text to a member
  with a small function, and `evaluate` compares members. Output is unchanged.
- `report.wlo`: `enum Sort` (`COUNT`, `NAME`) and `enum ColorMode` (`AUTO`,
  `ALWAYS`, `NEVER`). Option text is mapped through `dict[str, Sort]` and
  `dict[str, ColorMode]` with `.get`, and a `None` result is the usage error.
  `Options.sort` becomes `Sort`. Output and exit statuses are unchanged.
- The Rosetta Code example prints the members of an enum and gives them values
  through a `dict[Fruit, int]`, since Willow enum members carry no values.

## Test plan

- `tests/unit/parser_test.lua` `defaults`: `E.A` and `m.E.A` parse as defaults;
  `x`, `f()`, and the other existing cases report the new message.
- `tests/unit/bind_test.lua` `enums`: a parameter and a field default resolve
  to the `EnumMember` of the right enum, also through an imported module;
  `x: E = E.C` reports "enum 'E' has no member 'C'"; `x: F = E.A` reports
  "expected F, received E"; `x: int = q.A` reports "unknown enum 'q'".
- Bind and check dictionary key tests: `dict[E, int]` binds; `dict[E | F, int]`
  and `{1.5: 2}` report the new message; update the existing three assertions
  to the new message; a display `{E.A: 1, F.A: 2}` reports "expected E, received F".
- `tests/programs/enums.wlo`: call a function and construct a class with an
  omitted enum default and with an explicit argument; build a
  `dict[ColorMode, str]` from a display, index it, test `in`, iterate it in
  insertion order, and look up a missing member with `.get`.
- `tests/modules/qualified`: a `models.E.MEMBER` parameter default.
- Existing `calc_example` and `report_example` in `tests/unit/cli_test.lua`
  pass unchanged; run `examples/rosettacode/enumerations.wlo` against its
  `.out`.

## Implementation plan

- `compiler/types.lua`: add `is_key`.
- `compiler/parser.lua`: accept dotted names in `parse_default`; update the message.
- `compiler/bind.lua`: move `enum_named` to module level, add `resolve_member`,
  pass `module` to `check_default` and type enum defaults there; use
  `types.is_key` in `resolve_type`.
- `compiler/check.lua`: use `types.is_key` for displays; copy `enum` and `name`
  in `bind_args`.
- `compiler/lower.lua`: update the `lower_args` comment ("literals or enum members").
- Tests listed above.
- `examples/stdlib/calc.wlo`, `examples/stdlib/report.wlo`: use enums as decided.
- `examples/rosettacode/enumerations.wlo` and `.out` (created).
- `agents/todo.md`: check off the task and the milestone.
