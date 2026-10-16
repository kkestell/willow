# Filesystem, environment, and time

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-16-003-filesystem-environment-and-time.md`: `runtime/host.lua`,
the `fs`, `sys`, and `time` declarations in `compiler/bind.lua`, the signatures in
`compiler/check.lua`, conditional host runtime inlining in `compiler/emit.lua`,
`examples/listing.wlo`, the new tests, and the §10, §14, and §18 changes in
`docs/spec.md`, against the plan and the accepted §18 text. Traced the callers in
`compiler/lower.lua`, the record and exception representation in `runtime/core.lua`,
and the `willow run`, `willow test`, and `willow build` process models. The
`struct stat` and `struct dirent` layouts were checked by reading against the
platform headers. Programs ran on macOS arm64 only. Linux and macOS x64 rely on
the reported container runs and on reading the code.

## Fixed

- **Symlink following in `fs.stat` was untested** (`tests/unit/cli_test.lua:511`):
  The plan calls for checking `fs.stat` of a symlink with and without
  `follow_symlinks`, but only the `lstat` path ran against a symlink. A wrong
  `stat` symbol or layout for followed links would go unnoticed. The listing test
  now runs a small program that prints both kinds for the symlink and expects
  `file symlink`.
- **`utc` rounding rule lost in the spec fold** (`docs/spec.md:1053`): The folded
  text said `utc` "drops fractions of a second", which reads as truncation toward
  zero and disagrees with the accepted rule and the implementation for negative
  timestamps (`utc(-0.5)` is `1969-12-31T23:59:59Z`). It now says `utc` rounds
  down to whole seconds.
- **Host runtime locals reduced the program size limit** (`compiler/emit.lua:17`):
  The host runtime added 41 top-level locals to the main chunk, which shares
  LuaJIT's 200-local limit with the core runtime and the entry module's
  functions, so a program using `fs`, `sys`, or `time` failed at about 68 entry
  functions instead of about 102. `emit` now inlines each optional runtime file
  (the case conversion runtime as well as the host runtime) inside a `do` block,
  declaring before it only the helpers the file defines without `local`. The
  host runtime now costs 17 locals and the case runtime 2; an entry module fits
  85 functions with host calls and 83 with host and case calls. The remaining limit belongs to the specified
  layout, as the 2026-10-14-007 review recorded, and applies only to the entry
  module, since other modules keep their functions in tables.

## Findings

None open.

## Checks run

- `make test`: 226 passed, 0 failed (macOS arm64, after the fixes).
- Generated programs after the fix, counting `main`: 85 entry functions with
  host calls run and 86 fail; 83 with host and case calls run and 84 fail; 102
  without either run and 103 fail.
- Ad hoc programs on macOS arm64: `fs.stat` through and on a symlink, `exists`
  on a dangling symlink, `dirname` of `a/` and `/a/`, `mkdir` with `parents`
  and trailing slashes, `exist_ok` on an existing directory, `mkdir("/",
  exist_ok=True)`, `rename` and `listdir` error messages, `getenv("")`, and
  `isinstance` with `fs.Stat`. All matched the spec.
- `willow build` of a program using `listdir`, `environ`, `stat`, `monotonic`,
  and `utc`; the executable ran correctly.
- Generated programs with 40 to 112 entry functions, with and without host and
  case calls, to measure the local-variable limit.

## Verdict

The implementation matches the plan and the folded spec on the paths checked.
Three findings were fixed, including the host runtime's cost against LuaJIT's
local limit, and none remain open.
