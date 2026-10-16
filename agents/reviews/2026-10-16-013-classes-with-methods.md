# Classes with methods

## Scope and coverage

Reviewed the staged implementation of
`agents/plans/2026-10-16-013-classes-with-methods.md`: method parsing in
`compiler/parser.lua`, method binding and the `native_methods` rename in
`compiler/bind.lua`, method-call checking and the missing-return wording in
`compiler/check.lua`, direct-call lowering in `compiler/lower.lua`, class tables
and traceback labels in `compiler/emit.lua`, the renamed diagnostics, the
`docs/spec.md` and `agents/todo.md` edits, `examples/shapes.wlo`, and the new and
updated tests. Callers of the changed code (native method lookup, field access,
test discovery, entry-module exports) were traced against the plan's decisions.

Gaps:

- None material. The LuaJIT local and upvalue limits on very large programs
  predate this change and were not reviewed further.

## Summary

No findings.

## Checks run

- `make test`: 266 passed, 0 failed.
- Ran scratch programs: method calls after `isinstance` narrowing on a union of
  two classes with same-named methods, on list and dict elements, and with
  comments and blank lines in class bodies. All printed the expected output.
- Ran a two-module project where an imported module's class method calls a
  private module function and an entry-module function, and the entry module
  imports itself and constructs `app.Box`. Inspected the generated Lua for the
  `__wlo_class_Box` and `__wlo_class_my__geo_0Point` tables.
- Ran a qualified exception class with methods, including one named `end`,
  caught with `except geo.GeoError as e`.
- Ran `willow test` on a file whose class has a method named `test_inner`. Only
  the top-level `test_get` was discovered.
- Confirmed the receiver is evaluated before arguments when an argument replaces
  the receiver's field or list element (`h.c.get(swap(h))`,
  `xs[0].get(clear(xs))`).
- Ran `willow check` on a missing `self`, a non-`self` first parameter, an
  annotated `self`, a field after a method, a bad method default, `A.f` as a value
  and as a call, and a method after `pass` in an exception class. Each gave the
  planned or existing diagnostic.

## Verdict

The implementation matches the plan and the spec. No changes needed.
