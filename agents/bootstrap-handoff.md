# Bootstrap handoff

Where the native bootstrap in `agents/bootstrap.md` stands and what comes
next. The swarm runs as `agents/bootstrap-swarm.md` describes. Updated
2026-10-24, after PR #84 merged.

## State

- Milestones 1 through 6 are done. Stage 0 (`bootstrap/stage0`, Rust)
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
- Stage 1 compiles the full language in `docs/spec.md` §1-§13 and §15:
  exceptions with tracebacks, keyword arguments and defaults, tuples,
  format specifications, bytes and `input`, generics (monomorphized per
  instantiation) and protocols, function values and closures, standard
  protocols and `with`, the iterable built-ins, sorting, the full set of
  string methods with Unicode 17.0 case tables in core, generators, and
  async with task groups, cancellation, and semaphores. Of §14 it has only
  the `aio` parts the async programs need (`sleep`, `task_group`, `Task`,
  `semaphore`). Coroutines (generators and tasks) run on 256 KiB stacks
  from the GC heap, switched by arm64 assembly that `willow1` appends to
  QBE's output; creating a coroutine on amd64 fails with a clear error.
- `stage1.sh` runs `tests/programs/` under `willow1` except the programs in
  `bootstrap/tests/stage1-pending`; 75 of 110 pass. Of the 35 pending, 30
  need §14 standard library modules (milestone 7). `overflow_add`,
  `overflow_sub`, `stdlib_builtins_errors`, and `text_conversions` expect
  the Lua implementation's 53-bit integer range rather than spec §4's
  64-bit range, as does `tests/modules/runtime_frames`, and leave the list
  when the Lua implementation is deleted. `type_errors` expects every
  checker error, and stage 1 reports the first.
- Stage 1 reaches the fixpoint: `willow1` built by `willow0` and `willow1`
  built by itself emit byte-identical IL for stage 1's source. `stage1.sh`
  checks it on every native run.
- The binder checks type-argument bounds and protocol overlap after lazy
  types resolve, so `Box[list[int]]` satisfies `Box[T: Iterable[int]]`. The
  Lua binder rejects it; the regression cases in `bind_test.wlo` record the
  divergence.
- Core is compiled into every program whole, so a small program's build
  takes about 110 ms and `stage1.sh` about 40 s.
- A generic recursive alias applied to an outer type parameter
  (`def f[T](n: Nested[T])`) makes substitution recurse without end, as in
  `compiler/types.lua`.
- `make bootstrap-test` and `make test` pass on Linux arm64 and macOS
  arm64. amd64 has no test machine.

## Next

Milestone 7: stage 2 in full Willow, the standard library ported to `lib/`,
the test runner in Willow, and the Lua implementation deleted
(`agents/bootstrap.md` §11). The 30 standard-library programs in
`stage1-pending` are its first conformance targets.

## Resuming elsewhere

Create a fresh swarm from the swarm notes; the code, the pull request
reviews, and these documents carry what the new agents need. Testing on macOS
before merging needs `qbe`, `bdw-gc`, and `pkg-config` from Homebrew and a
Rust toolchain; LuaJIT (`make`) is needed only for `stage1.sh --lua`.
