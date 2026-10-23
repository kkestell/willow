# Operating the bootstrap swarm

How the work in `agents/bootstrap.md` is run with gnat. The operator is a
Claude Code session on the developer's machine; agents run in Docker and open
pull requests against `main`.

## Repository conventions for this work

- Work happens on `main`. `kkestell/willow-bak` is a private snapshot of
  every branch taken on 2026-10-23, before this work began, so `main` can be
  changed freely. It is not kept in sync.
- The active `gh` account must be `kkestell`, since gnat takes `GH_TOKEN` from
  it. It was switched there on 2026-10-23.
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
gnat agent create willow-bootstrap reviewer1 --profile reviewer --harness claude --model claude-opus-5-5 --effort high --instructions "$(... '/^### Reviewer instructions/,/^### /p' ...)"
gnat up willow-bootstrap
```

Two coders and one reviewer through milestone 2. Grow to four coders at
milestone 3, when stage 1 splits by compiler phase and runtime subsystem.
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

Tasks follow the milestones in agents/bootstrap.md §11. Dependent tasks wait
for the previous merge, then the agent is told to merge origin/main first.

### Milestone 1, one coder

Send to coder1:

> Implement milestone 1 of agents/bootstrap.md: a vertical slice of stage 0.
> In bootstrap/stage0, write the lexer, parser, checker, and QBE emitter for
> the part of L0 that bootstrap/tests/programs/sum_to.wlo uses: `def` with
> annotated parameters and return types, `int`, `bool`, and `str` types,
> integer literals and string literals, `+`, `-`, `*`, `<=` and the other
> comparisons, assignment, `while`, `if`, `return`, `main`, and `print` of
> `int` and `str`. Implement the intrinsic layer from §5 as far as this slice
> needs: `ptr`, `word`, `__alloc` and `__alloc_atomic`, `__load8`,
> `__store8`, `__load1`, `__store1`, reinterpretation between `word` and
> `int`, `ptr`, and `str`, and `extern def`. Write the first
> bootstrap/core/core.wlo in L0 providing string objects with the layout in
> §4, string concatenation, and printing of `int` and `str` through `extern
> write`; stage 0 lowers `+` on strings and `print` to calls into core.
> Follow the value representation in §4, the symbol names in §7, and the
> driver behavior in §10: `willow0 build FILE -o OUT` runs qbe and cc with
> the target chosen from the host and libgc found through pkg-config, and
> `willow0 compile FILE -o OUT.ssa` writes the IL. Diagnostics use the spec
> §13 format. Done when `make bootstrap-test` passes on Linux, and the
> emitted IL is deterministic. Integer overflow checking, floor division,
> unions, lists, and dicts are later milestones; do not start them. You own
> bootstrap/stage0, bootstrap/core, and bootstrap/tests. Do not edit
> agents/bootstrap.md; report anything in it that turned out wrong.

While coder1 works, send coder2 a non-conflicting task: write the L0 program
tests for milestone 2 in a new directory bootstrap/tests/programs-pending/
covering strings, lists, dicts, unions and narrowing, f-strings, slicing,
conversions, enums, classes, and the fatal runtime failures, with expected
output taken from the spec and checked against the Lua implementation with
`./willow run`. The directory is renamed into programs/ as features land.

### Milestone 2, two coders

After milestone 1 merges, split by file: coder1 owns bootstrap/stage0 and
adds the checker and emitter for the remaining L0 features in §3; coder2
owns bootstrap/core and implements lists, dicts, boxing, conversions, and the
host functions. The lowering table between them is the core function names
in agents/bootstrap.md §4 and §5; the first task of milestone 2 is for
coder1 to write that table into bootstrap/core/API.md as signatures, which
coder2 then implements. Tests move from programs-pending/ to programs/ with
each feature.
