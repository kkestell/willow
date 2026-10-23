# Bootstrap handoff

Where the native bootstrap in `agents/bootstrap.md` stands and what comes
next. The swarm runs as `agents/bootstrap-swarm.md` describes. Updated
2026-10-23, when the swarm was paused at the 5-hour usage limit.

## State

- Milestones 1 and 2 are done. Stage 0 (`bootstrap/stage0`, Rust) compiles
  all of L0. Core (`bootstrap/core/core.wlo`) implements
  `bootstrap/core/API.md`, including `fs.exists`, `fs.realpath`, and
  `core.run`.
- Milestone 3 is one pull request from done. The stage 1 lexer, parser, module
  loader, types and standard library tables, and the binder's scope and name
  resolution are on `main` in `bootstrap/stage1/`. Stage 0 compiles them and
  `make bootstrap-test` runs them natively through `bootstrap/tests/stage1.sh`;
  `stage1.sh --lua` runs them under the Lua implementation instead.
- `make bootstrap-test` passes on Linux arm64 and macOS arm64. amd64 has no
  test machine.

## Open: PR #56

PR #56 (`willow-bootstrap/coder3/stage1-bind-types`) connects the binder to the
loader, types, and standard library and adds the `bind_files` driver. Every
program in `tests/` and `examples/` binds with Lua's binder errors. The review
requested two changes:

1. Type-parameter bounds are checked before list and dict element types are
   resolved, so valid programs crash stage 1 with
   `alias ... is used before it is resolved`: `class Box[T: Iterable[int]]`
   used as `Box[list[int]]`, its variants in the review, and a local
   `x: Iterable[int] | list[str] = []`. Defer these checks the way union
   overlap is deferred, add regression tests, and comment that this
   deliberately differs from Lua, which wrongly rejects or crashes on them.
2. The `bind_files` pass rule only checks errors stage 1 reports. Also list
   the corpus programs whose first error comes from loading or binding (today
   `tests/programs/unknown_escape.wlo` and
   `tests/modules/missing_module/main.wlo`) and fail when one of them binds
   without its error.

Optional, from the same review: key lazy types by id, not source text, in
`types.wlo`'s recursion guards.

## Next

1. Fix, review, and merge #56. That completes milestone 3.
2. Milestone 4, starting with one coder's vertical slice: the stage 1 checker
   and QBE emitter for `sum_to.wlo` and `core`, and a `willow1` driver with
   `build` and `compile` like willow0's, which runs `qbe` and `cc` through
   `core.run` (with `sh -c` for the `pkg-config` fallback). Then split the rest
   of L0 by feature, as the swarm notes describe.
3. Milestone 5: stage 1 builds itself and the IL matches.

## Resuming elsewhere

The paused swarm's agent sessions exist only on the machine that ran it.
Elsewhere, create a fresh swarm from the swarm notes; the code, the pull
request reviews, and these documents carry what the new agents need. Testing
on macOS before merging needs `qbe`, `bdw-gc`, and `pkg-config` from Homebrew
and a Rust toolchain; LuaJIT (`make`) is needed only for `stage1.sh --lua`.
