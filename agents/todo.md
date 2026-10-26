# TODO

- Base unions and type tests on runtime classes. Replace the union member
  restrictions with the disjoint-coverage rule, allowing open types (protocols
  and type parameters) only alongside `none`; this makes protocol-to-union
  conversion unambiguous, replacing the first assignable member choice in
  `compiler/emit.wlo`. Use `is` and `is not` for type tests, replacing
  `isinstance`, with every non-open type name and alias accepted, and narrow to
  the covered members. Reject `none` operands of `==` and `!=`, pointing to
  `is none`, and point `is` with an enum member to `==`. Update compiler checks,
  diagnostics, and editor support; migrate sources and tests, including union
  tests that pair protocols with other types, and cover alias tests, open-type
  unions, and unsupported type tests. Validate on macOS and Linux.
- Stop reserving `del`, `from`, and `global` in the compiler and editor support;
  keep `match` and `case` reserved for future use. Add focused regression coverage
  for the freed identifiers and the retained reserved words.
- Add explicit local `var` declarations, including annotated declarations
  without initializers and tuple patterns. Make assignment update an existing
  binding, and treat initializers as assignments for definite assignment and
  narrowing. Adapt type inference, diagnostics, and editor support, with focused
  regression coverage.
- Implement lexical block scopes with declaration-order visibility and fresh
  bindings on each block execution and loop iteration. Scope loop, handler, and
  resource bindings to their bodies; preserve assignments to enclosing bindings.
  Reject declarations, including nested function and lambda parameters, that
  reuse a visible local, parameter, or nested function name. Cover rejected
  redeclarations, sibling reuse, loop captures, and task handles used after group
  exit.
- Resolve closure reads and writes to the same enclosing binding and remove
  `nonlocal` syntax and its keyword reservation. Keep shared mutable captures
  alive after scope exit; cover counters and captures from separate iterations.
- Migrate sources, tests, documentation, and examples to explicit declarations
  and lexical scopes, including values assigned across branches and task-group
  boundaries. Validate on macOS and Linux with `make bootstrap-test`.
- Make `str.find` and `bytes.find` return `int | none` instead of `-1`. Migrate
  call sites in `lib/`, `compiler/`, tests, and examples, and cover found and
  missing results. Validate on macOS and Linux.
- Require the `d.get(k, default)` default to be assignable to `V`, removing the
  `none`-default form and its result-type rule. Cover the rejected default.

---

- amd64 has no test machine. Creating a coroutine on amd64 fails with a clear
  error. On Intel macOS, `fs.stat` and `fs.listdir` use the arm64 `stat` and
  `dirent` layouts and unsuffixed symbols, where the x86_64 ABI needs the
  `$INODE64` entry points.
- `willow run` rejects a program argument that is not valid UTF-8 in its own
  `sys.args()`; a built executable receives it and raises `ValueError` as
  specified.
- A failed write to stdout or stderr reports `cannot write output: <reason>`
  without the call's source location.
- `subprocess`'s async methods check child status every 10 ms rather than
  waiting on pipe readiness.
- The checker reports the first error in a program.
