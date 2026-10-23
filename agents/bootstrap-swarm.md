# Operating the bootstrap swarm

How the work in `agents/bootstrap.md` is run with gnat. The operator is a
Claude Code session on the developer's machine; agents run in Docker and open
pull requests against `main`.

## Repository conventions for this work

- Work happens on `main`.
- gnat takes `GH_TOKEN` from the environment, or else from the active `gh`
  account, which may not be `kkestell`. Run `gnat up` with
  `GH_TOKEN=$(gh auth token -u kkestell)` exported.
- Commits have a subject and body in the repository's style and no
  attribution trailers.
- Merges use merge commits, matching the history. Before merging, the operator
  tests the combined result on macOS from a scratch clone of `origin/main`
  with the PR branch merged in: `make bootstrap-test`, and `make test` when
  Lua files changed. Agents can only test Linux.

## Swarm definition

```sh
gnat create willow-bootstrap --repo kkestell/willow --dockerfile bootstrap/Dockerfile
gnat agent create willow-bootstrap coder1 --profile coder --model claude-opus-5-5 --effort high --instructions "$(cat agents/bootstrap-swarm.md | sed -n '/^### Coder instructions/,/^### /p' | sed '1d;$d')"
gnat agent create willow-bootstrap coder2 --profile coder --model claude-opus-5-5 --effort high --instructions "..."   # same text
gnat agent create willow-bootstrap coder3 --profile coder --model claude-opus-5-5 --effort high --instructions "..."   # same text
gnat agent create willow-bootstrap reviewer1 --profile reviewer --harness claude --model claude-opus-5-5 --effort high --instructions "$(... '/^### Reviewer instructions/,/^### /p' ...)"
gnat up willow-bootstrap
```

Three coders and one reviewer: two finish milestone 2 while the third starts
stage 1 (see Task sequence). Idle coders review each other's PRs.
Check `gnat status` for the account's usage limits before starting.

### Coder instructions

You implement changes to the Willow repository as part of a bootstrap of a
self-hosting native compiler. Before any task, read AGENTS.md and
agents/bootstrap.md; the second is the design you are implementing and the
answer to most questions. docs/spec.md defines the language and every
behavior of the L0 subset is exactly what the spec says.

For each task: fetch and create a new branch off the latest origin/main.
Commit in the repository's style, a subject and a body with no attribution
trailers. Push the branch and open a pull request against main. Force-pushing
is refused, so to bring a branch up to date merge origin/main into it; do not
rebase.

Before pushing run `make bootstrap-test`, and `make test` if you changed any
Lua file. Your container is Linux arm64. Every change must also work on
macOS arm64, which the operator tests before merging; follow the portability
rules in agents/bootstrap.md and say in your report what you could not test.
Do not add dependencies or crates without asking.

Work only on what you were given, in the files you were given. Put
suggestions for other work in your final report rather than messaging
teammates, so the operator decides who does them. If a task needs a decision
that the design does not make, stop and ask in your report instead of
guessing.

End every turn with a short report: the PR URL, what changed, what you
tested and on which platform, and anything blocked or needing a decision.

### Reviewer instructions

You review pull requests to the Willow repository for a bootstrap of a
self-hosting native compiler. Read AGENTS.md and agents/bootstrap.md first;
review against them and against docs/spec.md.

For each PR you are sent: check out its branch, build it, run
`make bootstrap-test`, and exercise what the PR claims directly, including
behaviors the existing tests do not cover. Check that the change keeps the
contracts the rest of the design relies on: value representation, the core
API, portability rules, and spec semantics. Do not change files, commit, or
push. Post your findings as a review on the PR with `gnat-container pr
review`, stating for each finding the file and line and how to reproduce it,
and end with an explicit verdict: approve, request changes, or blocked and
on what. End your turn with that verdict and a two-sentence summary.

### Reviewer scope

Have the reviewer build and run each PR, not only read it. When several PRs
arrive at once, have an idle coder review another coder's PR with the
reviewer instructions rather than queueing them all on the reviewer.

## Task sequence

Tasks follow the milestones in agents/bootstrap.md §11. Split work by
feature, end to end, not by layer: an agent that owns a library its
teammate's code must first call writes code it cannot test. Branch every task
off the latest `origin/main`, never off an unmerged PR; when the next task
depends on an open PR, give the agent independent work or let it wait. Merge
each PR as soon as it is approved and passes on macOS. Put "main moved" notes
in the next task message rather than sending them alone.

### Status

Milestones 1 and 2 are done: stage 0 compiles all of L0, core implements
bootstrap/core/API.md, and stage 0 compiles the stage 1 lexer. Milestone 3
is in progress in bootstrap/stage1/.

### Milestone 3

Stage 1 is written in L0 in bootstrap/stage1/. Stage 0 compiles it, and it
also runs under the Lua implementation (`./willow run`), which helps when a
stage 0 bug is suspected. The order is the lexer, then the parser and AST,
then the binder, each with a driver over every `.wlo` file in tests/ and
examples/. Grow to four coders when the parser lands and the binder and the
remaining front-end work can be split by feature.

### Milestones 4 and 5

Start with a vertical slice by one coder, as milestone 1 did: the stage 1
checker and QBE emitter for what `sum_to.wlo` needs, compiling `core` too,
with a stage 1 driver (`willow1 build`, `willow1 compile`) that behaves like
willow0's. Then split the rest of L0 by feature, end to end through checker,
emitter, and core where needed, each feature moving its programs from
`bootstrap/tests/programs/` into a stage 1 run of the same runner. The
checker follows `compiler/check.lua`'s rules and wording; the emitter follows
stage 0's value representation and symbols (agents/bootstrap.md §4, §7) but
need not emit identical IL. When all of `bootstrap/tests/` passes under
stage 1, build stage 1 with itself and compare the IL (milestone 5).
