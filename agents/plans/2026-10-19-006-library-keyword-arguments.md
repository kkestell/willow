# Library keyword arguments

## Goal

Finish the keyword-arguments milestone in `agents/todo.md` (spec §5 Calls,
§7, §14). Every standard-library function and every string, bytes, list,
dict, and native method accepts keyword arguments by the parameter names the
spec documents. The intrinsics `print`, `input`, `len`, `range`, `int`,
`float`, `str`, `bytes`, `ord`, `chr`, and `isinstance` stay positional-only.
`iter` and `next` do not exist yet. `banner.wlo` declares `width` and `border`
on `frame` as keyword-only.

## Related code

- `compiler/stdlib.lua` — built-in and provided-module signatures. A signature with `names` accepts keywords. Every provided function and native method with parameters already has `names` except `sys.eprint`. The intrinsic `bytes` wrongly has `names`.
- `compiler/check.lua` `STRING_METHODS` and `method_signature` — string, list, dict, and bytes methods return no names today, so `bind_args` treats them as positional-only.
- `examples/stdlib/banner.wlo` and its `banner_example` test in `tests/unit/cli_test.lua`.

## Decisions

- Names follow the spec's tables:
  - `startswith(prefix)`, `endswith(suffix)`, `find(sub)`, `replace(old, new)`,
    `split(sep)`, `ljust(width)`, `rjust(width)`, and `join(items)`;
  - `append(v)` on lists, and `get(k)` and `pop(k)` on dicts;
  - `eprint(value)` in `sys`.
  `STRING_METHODS` entries gain a third element for the names, and
  `method_signature` returns names for these methods.
- Methods and functions without parameters keep no names, so a keyword
  argument still reports "does not accept keyword arguments". `list.sort`
  already binds `reverse` by name through `SORT_PARAMS`.
- `bytes` loses `names` and becomes positional-only like the other intrinsics.

## Test plan

- `tests/unit/check_test.lua`: `bytes(values=[1])` reports
  "'bytes' does not accept keyword arguments"; `s.find(x='a')` reports
  "'find' has no parameter 'x'"; `'a'.strip(x=1)` stays rejected.
- `tests/programs/named_arguments.wlo` and `.out`: keyword calls to
  `startswith`, `replace` with keywords in reverse order, `join`, `ljust`,
  `append`, `get`, `pop`, and `sys.eprint(value=...)` (the program's stderr
  goes to a `.err` file only if it already has one, so use a stdout call
  instead if not).
- `banner_example` in `tests/unit/cli_test.lua` passes unchanged.

## Implementation plan

- `compiler/check.lua`: names in `STRING_METHODS` and `method_signature`.
- `compiler/stdlib.lua`: `names` for `sys.eprint`; remove `names` from `bytes`.
- `examples/stdlib/banner.wlo`: `def frame(text: str, *, width: int = 0, border: str = "*")`.
- Tests listed above; `agents/todo.md`: check off the task and the milestone.
