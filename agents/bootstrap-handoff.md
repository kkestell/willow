# Bootstrap handoff

Where the native bootstrap in `agents/bootstrap.md` stands and what comes
next. The swarm runs as `agents/bootstrap-swarm.md` describes. Updated
2026-10-23, after PR #56 merged.

## State

- Milestones 1, 2, and 3 are done. Stage 0 (`bootstrap/stage0`, Rust)
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
- The binder checks type-argument bounds and protocol overlap after lazy
  types resolve, so `Box[list[int]]` satisfies `Box[T: Iterable[int]]`. The
  Lua binder rejects it; the regression cases in `bind_test.wlo` record the
  divergence.
- `make bootstrap-test` passes on Linux arm64 and macOS arm64. amd64 has no
  test machine.

## Next

1. Milestone 4, starting with one coder's vertical slice: the stage 1 checker
   and QBE emitter for what `sum_to.wlo` needs, compiling `core` too, and a
   `willow1` driver with `build` and `compile` that behaves like willow0's,
   running `qbe` and `cc` through `core.run` (with `sh -c` for the
   `pkg-config` fallback).
2. Then split the rest of L0 by feature, end to end through checker, emitter,
   and core where needed. Each feature moves its programs from
   `bootstrap/tests/programs/` into a stage 1 run of the same runner. The
   checker follows `compiler/check.lua`'s rules and wording; the emitter
   follows stage 0's value representation and symbols (`agents/bootstrap.md`
   §4, §7) but need not emit identical IL. Branch every task off the latest
   `origin/main`, never off an unmerged PR.
3. Milestone 5: when all of `bootstrap/tests/` passes under stage 1, build
   stage 1 with itself and compare the IL.

## Resuming elsewhere

Create a fresh swarm from the swarm notes; the code, the pull request
reviews, and these documents carry what the new agents need. Testing on macOS
before merging needs `qbe`, `bdw-gc`, and `pkg-config` from Homebrew and a
Rust toolchain; LuaJIT (`make`) is needed only for `stage1.sh --lua`.
