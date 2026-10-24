# Bootstrap handoff

Where the native bootstrap in `agents/bootstrap.md` stands and what comes
next. The swarm runs as `agents/bootstrap-swarm.md` describes. Updated
2026-10-24, after PR #67 merged.

## State

- Milestones 1 through 5 are done. Stage 0 (`bootstrap/stage0`, Rust)
  compiles all of L0. Core (`bootstrap/core/core.wlo`) implements
  `bootstrap/core/API.md`, including `fs.exists`, `fs.realpath`, and
  `core.run`.
- The stage 1 front end in `bootstrap/stage1/` is complete: lexer, parser,
  module loader, types and standard library tables, and the binder. Every
  program in `tests/` and `examples/` loads and binds with the Lua
  implementation's first error. Stage 0 compiles it and `make bootstrap-test`
  runs it natively through `bootstrap/tests/stage1.sh`; `stage1.sh --lua` runs
  it under the Lua implementation instead, which helps when a stage 0 bug is
  suspected.
- Stage 1's checker, QBE emitter, and `willow1` driver compile L0. For every
  program, stage 1 checks and emits all of core, keeping `__os` arm pruning.
  Every top-level program in `bootstrap/tests/programs/` and
  `bootstrap/tests/core/` passes under stage 1.
- Stage 1 reaches the fixpoint: `willow1` built by `willow0` and `willow1`
  built by itself emit byte-identical IL for stage 1's source. `stage1.sh`
  checks it on every native run.
- The binder checks type-argument bounds and protocol overlap after lazy
  types resolve, so `Box[list[int]]` satisfies `Box[T: Iterable[int]]`. The
  Lua binder rejects it; the regression cases in `bind_test.wlo` record the
  divergence.
- `make bootstrap-test` passes on Linux arm64 and macOS arm64. amd64 has no
  test machine.

## Next

Milestone 6: the rest of the language in stage 1, with `core` grown to the
full runtime in the order `agents/bootstrap.md` §11 gives: exceptions,
closures, tuples, protocols and generics, generators, async. Each slice
passes its `tests/programs/` cases, and the fixpoint check still passes.

## Resuming elsewhere

Create a fresh swarm from the swarm notes; the code, the pull request
reviews, and these documents carry what the new agents need. Testing on macOS
before merging needs `qbe`, `bdw-gc`, and `pkg-config` from Homebrew and a
Rust toolchain; LuaJIT (`make`) is needed only for `stage1.sh --lua`.
