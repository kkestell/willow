# Bootstrap handoff

Where the native bootstrap in `agents/bootstrap.md` stands. The swarm runs as
`agents/bootstrap-swarm.md` describes. Updated 2026-10-24, after PR #106
merged.

## State

- Milestones 1 through 7 are done. `make` builds willow0 (Rust), willow1
  (stage 1, L0), and stage 2 from `compiler/*.wlo`, which builds itself;
  `build/willow` is that stage 2. Both fixpoints hold.
- Stage 2 implements every command in spec §12, including projects,
  `willow test`, and `willow init`. Stage 1 is frozen; compiler changes go to
  `compiler/`.
- The standard library is Willow source in `lib/`, embedded in the compiler
  with core. Lib modules may use the intrinsic layer, resolve imports only
  within `lib/` and core, and declare native types with `_` fields
  (`agents/bootstrap.md` §5). `http` loads libcurl with `dlopen` on first
  request.
- `make test` and `make bootstrap-test` run every program in
  `tests/programs/` and `tests/modules/`, the command cases, and the
  bootstrap suites through `tests/runner.wlo`, with nothing pending. They pass
  on Linux arm64 and macOS arm64.

## Known gaps

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

## Resuming elsewhere

Create a fresh swarm from the swarm notes. Building needs `cargo`, `qbe`,
`cc`, libgc, and `pkg-config` (Homebrew on macOS).
