# TODO

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
- A generic recursive alias applied to an outer type parameter
  (`def f[T](n: Nested[T])`) makes substitution recurse without end.
- Migrate library sources, examples, tests, documentation, and editor support
  to the lowercase literals. Handle the bootstrap transition while preserving
  the frozen stage 1 compiler; add regression coverage and validate the
  bootstrap on macOS and Linux.
- Replace `elif` with `else if` in the compiler and editor support; migrate
  sources and examples, and add regression coverage for branch chains and
  narrowing. Preserve the frozen stage 1 syntax during the bootstrap
  transition and validate on macOS and Linux.
- Replace the empty tuple type spelling `tuple[()]` with `tuple[]` in the
  compiler, diagnostics, and editor support; migrate sources and tests and
  add regression coverage. Preserve the frozen stage 1 syntax during the
  bootstrap transition and validate on macOS and Linux.
- Replace `lambda parameters: expression` with `(parameters) => expression`
  in the compiler and editor support; migrate sources and examples, and add
  regression coverage for parameter lists, precedence, and captures. Preserve
  the frozen stage 1 syntax during the bootstrap transition and validate on
  macOS and Linux.
- Allow optional lambda parameter annotations, with expected types supplying
  unannotated parameters and the expected return type, and expression bodies
  determining return types. Update the compiler and editor support; cover
  standalone annotated lambdas, contextual inference, empty displays in bodies,
  missing types, and callable compatibility in regression tests.
- Make method receivers implicit as the reserved name `self` and omit them from
  class and protocol parameter lists. Reject `self` outside methods and as an
  assignment target. Update compiler binding, signatures, diagnostics, and editor
  support; migrate sources and examples, and cover method calls, bound methods,
  protocol matching, receiver captures, and misuse of `self`. Preserve the frozen
  stage 1 syntax during the bootstrap transition and validate on macOS and Linux.
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
  unions, and unsupported type tests. Preserve frozen stage 1 behavior during
  the bootstrap transition and validate on macOS and Linux.
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
  boundaries. Preserve frozen stage 1 behavior during the bootstrap transition
  and validate on macOS and Linux with `make bootstrap-test`.
- Make `str.find` and `bytes.find` return `int | none` instead of `-1`. Migrate
  call sites in `lib/`, `compiler/`, tests, and examples, and cover found and
  missing results. Preserve frozen stage 1 behavior during the bootstrap
  transition and validate on macOS and Linux.
- Require the `d.get(k, default)` default to be assignable to `V`, removing the
  `none`-default form and its result-type rule. Cover the rejected default.
