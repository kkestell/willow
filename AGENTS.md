Keep this document accurate and short.

## Purpose and scope

Willow is a small, statically typed language with Python-like syntax that compiles
to readable Lua for LuaJIT. Source files use `.wlo`. `docs/spec.md` specifies the
language.

- Build the small language we need now. This is an early implementation, not a
  production-hardening exercise.
- Target macOS and Linux.

## Code style

- Do less. Keep correct code simple, ordinary, and cheap to change. Follow KISS
  and YAGNI.
- Write idiomatic Lua. Prefer plain tables, direct functions, and explicit control
  flow. Keep responsibilities clear without turning every step into an abstraction.
- Solve the actual problem. Do not build frameworks, extension points,
  configuration systems, or fallback paths for hypothetical future needs.
- Handle expected invalid source and ordinary operation failures clearly. Do not
  turn every imaginable host failure or pathological program into a new subsystem.
- Trust internal invariants; fail clearly when they break. Avoid redundant checks,
  speculative recovery, and layers of defensive wrappers.
- Let repeated, concrete needs earn abstractions and dependencies. Measure before
  optimizing. Fix demonstrated problems rather than inventing them.
- Preserve specified language behavior. Simplify the implementation rather than
  silently changing evaluation order, typing, or error semantics.
- Comments explain non-obvious reasons. They do not narrate straightforward code.

## Validation

- Test observable language behavior: parsing, typing, execution, and useful
  diagnostics. Use a small number of representative examples and meaningful
  regression tests for actual bugs.
- Cover boundaries that establish a language rule or expose a plausible failure.
  Do not enumerate every permutation, mirror implementation details, or pursue
  exhaustive coverage of hypothetical edge cases.
- Match verification to the change. Use focused tests while working; run
  `make test` for compiler, runtime, or build behavior changes before delivery.
  Broaden checks only when a concrete risk or failure warrants it.
- For documentation, comments, and filename-only changes, inspect the relevant
  text and diff. Do not run full tests, builds, linters, or formatters unless
  explicitly required. A normal filesystem rename needs no content hashing.
- Use documented commands directly. Once appropriate checks pass, stop; do not
  repeat validation without a new change or unresolved concern.
- Report relevant failures and validation limitations plainly.

## Documentation

- `docs/spec.md` specifies the language. `README.md` explains setup and
  usage. `AGENTS.md` guides contributors. Plans and work records belong in
  `agents/` when needed.
- Keep each fact in one place. Most code changes need no new documentation file,
  plan, report, or comment. Create new documents when requested or clearly needed.
- Do not turn routine implementation choices into specification requirements.
  Resolve ordinary details in code; discuss changes to observable behavior or
  scope when necessary.
- Keep edits focused. Do not expand specifications into catalogs of hypothetical
  failures or add unrelated cleanup to a small task.
