# Small projects and reusable modules

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-16-009-small-projects-and-reusable-modules.md`: qualified
imports in `compiler/parser.lua`, namespace binding and qualified calls in
`compiler/bind.lua`, module table names in `compiler/emit.lua`, search roots and
module identity in `compiler/loader.lua`, the new `compiler/manifest.lua`, the
project command forms in `compiler/cli.lua`, recursive discovery in
`compiler/runner.lua`, the `examples/portcheck` project, `tests/modules/qualified`,
the new unit tests, the §1 and §12 rules and milestone framing in `docs/spec.md`,
and the README "Projects" section. Behavior was exercised with temporary projects
on macOS arm64. Linux behavior relies on the reported container run.

## Fixed

- **`"dependencies": null` is accepted** (`compiler/manifest.lua:198`): JSON
  `null` parses to a sentinel table with no `keys`, so it passed the list check
  and the manifest loaded with no dependencies, although the spec makes a wrong
  type an error. The check now rejects the `null` sentinel; a regression test
  covers it.
- **Malformed numbers are silently dropped** (`compiler/manifest.lua:137`): the
  number pattern matched text such as `1-2` that `tonumber` rejects, and the
  parser returned `nil` as the value, so `"dependencies": [1-2]` became an empty
  list instead of a JSON error. The parser now accepts a number only when it
  converts, and otherwise reports `expected a value` at its position; a regression
  test covers it.
- **Unreadable dependency modules are reported as missing**
  (`compiler/loader.lua:63`): a dependency-root file that exists but cannot be
  read (for example, permission denied) was skipped, and the import then failed
  with the primary root's `No such file or directory`. A read failure other than
  `ENOENT` in a dependency root now reports that file and its error, as the
  primary root does. The loader's unneeded forward declaration of `visit` became
  a local function.

## Findings

No open findings.

## Checks run

- Temporary projects: `"dependencies": null` and `[1-2]` (accepted before the
  fixes, rejected after), an unreadable dependency module (misreported before,
  `Permission denied` after), a duplicate import, a module that is also a
  namespace, an unknown qualified module, a namespace used as a value, recursive
  `willow test` with and without a trailing slash and with a narrowed path, and
  a built executable run from `/`.
- `tests/unit/cli_test.lua`: 36 passed.
- `make test`: 254 passed, 0 failed.

## Verdict

The milestone matches the plan and the spec. Three manifest and loader error
cases were fixed with no open findings.
