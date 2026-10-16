# Small projects and reusable modules

## Goal

Implement `docs/spec.md` §24: qualified imports (`import app.util`) with
namespace rules, module search roots, module identity by physical file,
missing and ambiguous module diagnostics, an optional `willow.json` with
`entry`, `source`, `dependencies`, and `tests`, the project forms of `check`,
`run`, `compile`, `build`, and `test`, and unchanged explicit-file workflows.
Deliver a multi-module network CLI that uses a local dependency, with a
documented workflow from a clean checkout to a distributed executable, and fold
§24 into the baseline spec.

## Related code

- `compiler/parser.lua` — the `import` loop, `parse_member` (`module.Type`), the
  `isinstance` class, and `except` class names, each allowing one `.`.
- `compiler/loader.lua` — `M.load(path, source, library)`: the entry directory,
  then provided modules, then `lib/`; `seen` keyed by name.
- `compiler/bind.lua` — `declare` (imports share the file namespace and fill
  `module.imported`), `lookup`, `resolve_named`, and the `Name`, `MethodCall`
  (`module.name(...)` becomes a `Call`), and `IsInstance` branches.
- `compiler/emit.lua` — `module_table` builds `__wlo_module_<name>`.
- `compiler/cli.lua` — `parse_args`, `translate`, `compile_test`, the `test`
  dispatch.
- `compiler/runner.lua` — `discover` (non-recursive `find`) and `M.test`.
- `tests/modules/missing_module/` — the missing-module message to keep.

## Decisions

- **Syntax.** `import a.b.c` records `{ name = "a.b.c", root = "a", span }`.
  Type references, `isinstance` classes, and `except` classes accept
  `NAME (. NAME)*`, storing every component but the last, joined with `.`, in
  `module`. In expressions, `a.b.f(x)` parses as before (method call on field
  access) and bind rewrites it.
- **Binding.** `module.imported` is keyed by full module names and
  `module.roots` holds root names. In `declare`, each import's root takes part
  in the shared namespace once, so several imports may share a root, but a root
  equal to a function, record, or alias name is a duplicate. Importing a name
  that is also a prefix of another import is an error at the later import:
  `'app' is imported as a module and as a namespace`. A `Name` whose name is an
  unshadowed root raises `module 'app' cannot be used as a value`; a
  `MethodCall` whose object is a chain of `Field`s on an unshadowed root `Name`
  spelling an imported module becomes a `Call` named `a.b.f`. Locals shadow the
  whole namespace because the root is looked up in scope first.
- **Emitted names.** `module_table` escapes each `_` in the module name as
  `__` and each `.` as `_0`, which keeps different module names distinct.
- **Loader.** `M.load(path, source, roots)` takes
  `roots = { primary, dependencies, library, entry_name }`. A module name maps
  to `<component>/.../<last>.wlo`. Resolution: the primary root (the entry's
  directory, or the project source root); then the dependency roots, where two
  or more matches raise `module 'x' is ambiguous: found in <a> and <b>` at the
  import; then a compiler-provided module (single names only); then `lib/`.
  A miss reports the primary root's open error, as now. Each resolved file's
  `realpath` identifies it: loading a second module name for a file already
  loaded raises `module 'b' is the same file as module 'a.b'`. The entry is
  registered first under `entry_name`, so importing that name yields the entry
  itself.
- **Manifest.** New `compiler/manifest.lua` reads `willow.json` from the
  current directory with a small JSON reader of its own and returns
  `{ entry, entry_name, source, dependencies, tests }` with paths joined to the
  manifest directory (`.` contributes no prefix). Errors are
  `willow.json: <problem>`: invalid JSON (with its position), not an object,
  `unknown key '<key>'`, `'<key>' must be a string` or `a list of strings`, an
  empty path, and an `entry` that is absolute, contains `..`, does not end in
  `.wlo`, or has a component that is not an identifier. `entry_name` is the
  entry's path without `.wlo`, with `/` as `.`.
- **Commands.** `check`, `run`, `compile`, and `build` without a source file use
  the manifest; `willow run -- args` passes `args`; a missing manifest is
  `error: no source file given and no willow.json in the current directory`. An
  explicit source file uses its directory as the primary root and ignores the
  manifest. `USAGE` lists the project forms.
- **Tests.** With a manifest, `willow test [--check] [path]` discovers
  `test_*.wlo` recursively under the given path or the `tests` directory, with
  `find` (which does not follow directory symlinks), and compiles each test with
  the project roots. Without a manifest, discovery and roots stay as in §17.

## Test plan

- `tests/unit/parser_test.lua`: `import app.util`; `app.util.Rec` and
  `list[app.util.Rec]` annotations; qualified `isinstance` and `except`.
- `tests/modules/qualified/` (`main.wlo`, `app/util.wlo`, `app/models.wlo`,
  `app/deep/leaf.wlo`): calls, constructors, annotations, `isinstance`, and
  `except` through qualified names; a record type name in output; cross imports
  between the submodules; privacy of `_` names.
- `tests/unit/bind_test.lua`: module-and-namespace conflict, root name clashing
  with a function, a local shadowing a namespace, a namespace used as a value,
  an unknown qualified module member.
- `tests/unit/cli_test.lua` `project_commands`: a temporary project with
  `willow.json`, `src/app/...`, a dependency root, and `tests/unit/test_*.wlo`:
  `check`, `run -- args`, `compile` and `build` running outside the tree,
  recursive `test`, `test --check`, a narrowed `test tests/unit`, an explicit
  file ignoring the manifest, the missing-manifest error, each manifest error,
  an ambiguous module, a same-file import through an overlapping root, the entry
  imported by its own name, and a missing module in a dependency import.
- `tests/unit/emit_test.lua`: module names `a.b` and `a_0b` give different
  tables.
- `portcheck_example`: the example project's tests pass and its built
  executable runs from another directory.

## Implementation plan

1. `compiler/parser.lua`: qualified imports and references.
2. `compiler/bind.lua`: imports, roots, conflicts, and qualified calls.
3. `compiler/emit.lua`: escaped module table names.
4. `compiler/loader.lua`: roots, ambiguity, identity, entry registration.
5. `compiler/manifest.lua`, `compiler/cli.lua`, `compiler/runner.lua`: project
   commands and recursive project tests.
6. Tests above.
7. `examples/portcheck/`: `willow.json` (`entry` `portcheck/main.wlo`, `source`
   `src`, `dependencies` `["vendor"]`, `tests` `tests`); `src/portcheck/main.wlo`
   (a `cli` parser for `host:port` targets, `--timeout`, and `--json`),
   `src/portcheck/probe.wlo` (connects with `net` and times the attempt);
   `vendor/textkit/table.wlo` (column formatting, the local dependency);
   `tests/test_probe.wlo` (an open port from a local listener and a closed one)
   and `tests/test_table.wlo`.
8. Fold §24 into `docs/spec.md`, document the project workflow in `README.md`,
   and check off the milestone in `agents/todo.md`.

## Documentation updates

- `docs/spec.md`: §12 describes qualified imports, search roots, identity, and
  projects (`willow.json` and the command forms); §12's tests subsection covers
  project test discovery; §1 mentions projects. §24 keeps one sentence saying
  where its rules live, the milestones introduction says every milestone is
  implemented, and the scope references stay with it.
- `README.md`: a "Projects" section walking through `examples/portcheck` from
  `willow test` to `willow build` and running the executable elsewhere.
- `agents/todo.md`: check off §24.
