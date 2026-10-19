# Review of generic aliases, bounds, and generic function values

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-19-015-generic-aliases-bounds-and-values.md`: the
parser's alias type parameters, bounds, and `Specialized` nodes; bind's
`apply_alias`, union substitution, bound resolution, and `Specialized` and
`SpecializedCall` resolution; check's bound-aware field and method access,
bound checks, and generic `FunctionValue`s; lowering's receiver prefix and
`FunctionValue` conversion; and the tests and example. The speculative reading
of `name[...]` as type arguments got the closest look. Each suspected problem
was reproduced with small programs against the staged compiler and against
`HEAD`.

Gaps:

- Protocols, protocol bounds, the rest of `typing`, iterators, and explicit
  method specialization are later work and were not reviewed.

## Summary

| ID | Severity | Category       | Fix   | Title                                                         |
| -- | -------- | -------------- | ----- | ------------------------------------------------------------- |
| F1 | Medium   | Correctness    | Fixed | Generic alias uses are capped per program and keyed by address |
| F2 | Medium   | Error handling | Fixed | Indexes read as type arguments lose their spans and errors    |
| F3 | Medium   | Error handling | Fixed | Diagnostics misname types built from generic aliases          |
| F4 | Low      | Comments       | Fixed | `resolve_alias`'s comment sits above `enter_type_params`      |

## F1. Generic alias uses are capped per program and keyed by address

Medium · Correctness · Fixed · `compiler/bind.lua:210`

`apply_alias` counted every application of an alias across the whole program
and reported "alias 'X' expands without end" after 100. Type objects are not
interned, so each use with a structural argument such as `Box[list[int]]` is a
new application. A valid program that uses such an alias more than 100 times
fails to compile.

The cache was also keyed by `tostring(arg)`, a table address, without keeping
the argument alive. When the result does not hold the argument, as when a union
argument is flattened into `T | None`, the argument can be collected and its
address reused by a different type, which would then get the cached result.

### Evidence

101 functions taking `Box[list[int]]`, with `type Box[T] = list[T]`, reported
`alias 'Box' expands without end`.

### Fix

Applications are a list of `{ args, type }` matched by argument identity, which
keeps the arguments alive. The limit now applies to the nesting depth of
applications, tracked per alias body scope, so only a recursive use with
growing arguments such as `type Grow[T] = list[Grow[list[T]]]` reaches it. Bind
tests cover 120 uses and the growing alias.

## F2. Indexes read as type arguments lose their spans and errors

Medium · Error handling · Fixed · `compiler/parser.lua:313`

`name[...]` is now parsed as type arguments whenever the brackets parse as
types, and turned back into an index by `ast.index_from_type`, which rebuilt the
index expression from the type node. That conversion differed from parsing the
brackets as an expression:

- Every `xs[i]` index took the span of `xs` instead of `[`, so runtime
  `IndexError` and `KeyError` locations moved.
- `xs[a | b]` reported "'xs' is not generic", and `xs[a | b] = 1` reported
  "cannot assign to this expression", instead of "unsupported operator '|'".
- `xs[None]` reported "unknown name 'None'", since `None` became a name.

### Evidence

`print(xs[i])` out of range reported column 11 instead of 13. Each diagnostic
above was compared with the `HEAD` compiler, which gave the expected one.

### Fix

`parse_specialized` reads the brackets both ways. When they parse as types, it
also parses them with the ordinary index parser (`parse_index`, factored out of
`parse_postfix`) and keeps the resulting `Index` node, or the diagnostic that
parse raised, on the `Specialized` or `SpecializedCall` node. Bind and the
assignment-target check use that node, or raise that diagnostic, when the
callee is not a generic function. `ast.index_from_type` is removed. Parser and
bind tests cover the span, `None`, and `|` cases.

## F3. Diagnostics misname types built from generic aliases

Medium · Error handling · Fixed · `compiler/bind.lua:134`

Lazy list elements and dict values take their names from the source text.
Inside a generic alias's body, a type parameter kept its own name, so
`Box[int]` with `type Box[T] = list[T]` displayed as `list[T]`, and
`Box[int]` and `Box[str]` were indistinguishable in errors. A generic alias
used inside `list` or `dict` dropped its arguments, so `list[Pair[int, str]]`
displayed as `list[Pair]`.

### Evidence

`x: Box[int] = "s"` reported `expected list[T], received str`, and
`y: list[Pair[int, str]] = "s"` reported `expected list[Pair], received str`.

### Fix

`type_text` names a type parameter by the type it stands for and writes a
generic alias's arguments as it does a generic class's. Check tests cover both
messages.

## F4. `resolve_alias`'s comment sits above `enter_type_params`

Low · Comments · Fixed · `compiler/bind.lua:247`

Moving `enter_type_params` ahead of the alias functions left the comment for
`resolve_alias` above `enter_type_params`.

### Fix

Moved the comment back to `resolve_alias`.

## Checks run

- Focused programs for index targets, nested and dotted indexes, f-strings,
  qualified generic values, bounds on later classes and aliases, field writes
  through bounds, generic values with defaults and keyword-only defaults, and
  union substitution, compared against `HEAD` where behavior should match.
- `tests/unit/parser_test.lua`, `bind_test.lua`, and `check_test.lua`: 141
  passed.
- `make test`: 314 passed, 0 failed.
- Every `examples/rosettacode/*.wlo` matches its `.out`, and every
  `examples/stdlib/*.wlo` passes `willow check`.

## Verdict

The change meets the plan. F1 rejected valid programs that use a generic alias
often, F2 changed index error locations and messages, and F3 misnamed alias
types in errors. All four findings are fixed and tested.
