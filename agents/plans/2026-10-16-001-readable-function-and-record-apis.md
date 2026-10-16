# Readable function and record APIs

## Goal

Implement `docs/spec.md` §16: trailing literal defaults on function parameters
and record fields, and `name=expression` arguments for functions, constructors,
and the library functions and methods with named parameters. Supplied arguments
are evaluated once in written order; omitted ones take their defaults. Deliver an
options-record example and fold §16 into the baseline spec.

## Related code

- `compiler/parser.lua` — `parse_function` (parameters), `parse_record`
  (fields; exception classes get `message` as `fields[1]`), `parse_arg` and
  `parse_args` (already build `Keyword` nodes), `parse_unary`.
- `compiler/bind.lua` `M.bind` — resolves field and parameter types, then
  `force_pending()` finishes aliases.
- `compiler/check.lua` — `builtins`, `method_signature`, `check_arity`,
  `positional_args` (the §15 `reverse`-only keyword handling, replaced here),
  the `Call` and `MethodCall` branches, and the `range` arguments in `For`.
- `compiler/lower.lua` — the `Call` branch (including the `sorted` default) and
  the `MethodCall` branch (including the `sort` default).
- `tests/unit/check_test.lua` `text_and_collections` — expects the §15 keyword
  messages.

## Decisions

- **Default syntax.** `parse_function` and `parse_record` accept `= default`
  after a parameter's or field's type and store it as `default`. `parse_default`
  accepts `None`, `True`, `False`, a `STRING` token, and an `INT` or `FLOAT`
  token optionally preceded by `+` or `-`, and returns the matching literal node
  with the sign folded into `value` (`0 - value` for an `Int`, so `-0` is `0`;
  `-value` for a `Float`, so `-0.0` stays negative). Anything else is
  `a default must be a literal` at its first token. A parameter or field without
  a default after one with a default is
  `parameter 'x' without a default follows one with a default` (or `field`) at
  its name. An exception class's `message` has no default, so its own fields may
  all have defaults.
- **Default types.** `M.bind`, after `force_pending()`, checks each default with
  `types.assignable(decl.type, literal_type)` and reports
  `expected T, received U` at the default, the message `expect_type` uses.
  `literal_types` maps `Int`, `Float`, `String`, `Bool`, and `None` to their
  types.
- **Positional after keyword.** `parse_args` reports
  `positional argument follows keyword argument` at a positional argument that
  follows a `Keyword`.
- **Binding arguments.** `bind_args(node, name, params, noun)` replaces
  `positional_args` and is called before argument checking in the `Call` and
  `MethodCall` branches. `params` is a list of `{ name, default }` (`name` nil
  for a positional-only callee); `noun` is `parameter` or `field`. In written
  order it places each positional argument at its index and each keyword at its
  parameter's index, recording the index in `node.order`. Errors, in this order:
  - a keyword for a positional-only callee:
    `'print' does not accept keyword arguments` at the keyword;
  - an unknown name: `'f' has no parameter 'x'` (`'P' has no field 'x'`);
  - a second value for one parameter:
    `'f' received more than one value for 'x'` at the keyword;
  - a count outside required..total: the existing `check_arity` message, so
    positional-only calls report as before;
  - an omitted required parameter: `'f' is missing argument 'x'` at the call.
  It then sets `node.args` to the arguments in parameter order, with a fresh
  literal node `{ kind, value, span = node.span }` copied from each omitted
  parameter's default, so check and lowering see one argument per parameter.
- **Signatures.** User functions pass `fn.params` and records their `fields`.
  `builtins` entries gain `names` for the library functions whose §14 parameters
  are named: `read_file` (`path`), `write_file` (`path`, `text`), and `exit`
  (`status`). `sorted` gets `names = { "items", "reverse" }` and
  `defaults = { [2] = false }`, replacing `required`; its first parameter is now
  named `items` in §7. `sort` passes `{ { name = "reverse", default = false } }`
  and the third result of `method_signature` goes away. Every other built-in and
  method, including `sys.eprint`, passes no names. Lua `false` defaults become
  `Bool` nodes when copied. `range` in `For` reports a keyword with the
  positional-only message and keeps its own arity check.
- **Evaluation order.** A new `lower_args(node)` in `lower.lua` lowers
  `node.args[i]` for each `i` in `node.order` first, then the remaining
  (default) arguments, and returns them in parameter order. `lower_operand`
  already moves calls, helper calls, and field reads into temporaries, and other
  expressions cannot change before the call, so arguments run in written order.
  The `Call`, `Construct`, and `MethodCall` paths use it, and the `sorted` and
  `sort` default insertions go away.

## Test plan

- `tests/unit/parser_test.lua`: defaults `= -1`, `= +2.5`, `= -0.0`, `= 'x'`,
  `= None`, `= True` on parameters and fields; rejected: `= f()`, `= x`,
  `= [1]`, `= f'a'`, `= -'a'`, `= -True`; a required parameter or field after a
  defaulted one; `f(a=1, 2)` rejected.
- `tests/unit/check_test.lua`: a default of the wrong type for a parameter and a
  field; `int | None = None` accepted; unknown keyword for a function and a
  constructor; duplicate by keyword and by position plus keyword; missing
  required argument with keywords; too many positional arguments; keywords on
  `print`, `len`, `s.find`, and `range`; `fs.write_file(text='x', path='p')`
  and `sys.exit(status=1)` accepted, and `sys.exit(status=1)` still transfers
  control; exception class fields with defaults; update the
  `text_and_collections` expectations (`sorted(reverse=True)` now reports
  `'sorted' is missing argument 'items'`).
- `tests/programs/named_arguments.wlo` and `.out`:
  - Function with defaults called positionally, by keyword in and out of order,
    and with defaults omitted; a `float` default formatting as a float; a
    `float | int` parameter receiving its `float` default.
  - Records constructed with keywords and defaults, including an exception class
    with a defaulted field raised and caught.
  - Written evaluation order with keywords out of declaration order, using
    printing functions, and a raising argument stopping the later ones.
  - `sorted(items=..., reverse=True)` and `json.dump(value=...)`.
- `tests/unit/cli_test.lua` `banner_example`: run `examples/banner.wlo` with and
  without flags and compare the output.

## Implementation plan

1. `compiler/parser.lua`: `parse_default`, defaults in `parse_function` and
   `parse_record` with the ordering error, and the positional-after-keyword
   error in `parse_args`.
2. `compiler/bind.lua`: `literal_types` and the default type check.
3. `compiler/check.lua`: `bind_args`, `names` and `defaults` on `builtins`, the
   `Call`, `MethodCall`, and `For` call sites; remove `positional_args`,
   `required`, and `method_signature`'s third result.
4. `compiler/lower.lua`: `lower_args` in the `Call` and `MethodCall` branches;
   remove the `sorted` and `sort` default insertions.
5. Tests above.
6. `examples/banner.wlo`: a `Options` record (`width: int = 24`,
   `border: str = "*"`, `upper: bool = False`) filled from `sys.args()` flags
   (`--upper`, `--border=C`, `--width=N`), and
   `frame(text: str, width: int = 0, border: str = "*") -> str` called as
   `frame(text, border=options.border, width=options.width)`.
7. Fold §16 into `docs/spec.md` and check off the milestone in `agents/todo.md`.

## Documentation updates

- `docs/spec.md`: §3 Functions gains defaults and drops "no default, named";
  §3 Records describes constructor defaults and keywords; §5 Calls replaces the
  exact-arity and `reverse` sentences with the binding rules, the errors, and
  written-order evaluation, and names the positional-only built-ins and
  methods; §7 names `sorted(items, reverse)`. The §16 heading stays with one
  sentence saying it is implemented and where its rules live. The top-of-file
  pointer and the milestones introduction say sections 17–24 are the
  unimplemented ones.
- `agents/todo.md`: check off "Readable function and record APIs (spec §16)".
