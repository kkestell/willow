# Command-line and terminal tools review

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-16-006-command-line-and-terminal-tools.md`: the `cli` and
`terminal` declarations in `compiler/bind.lua` and `compiler/check.lua`,
`runtime/cli.lua`, the terminal helpers in `runtime/host.lua`, the
`optional_runtimes` entry in `compiler/emit.lua`, `examples/report.wlo`, the
new tests, and the `docs/spec.md` and `agents/todo.md` updates. Checked them
against the plan and against the runtime code they depend on: `__wlo_fail`,
`__wlo_parse_int`, `__wlo_parse_float`, `__wlo_format_float`, `__wlo_list`,
`__wlo_fd`, the standard `io.File` handles, and `except` class matching. The
pseudo-terminal tests were run on macOS only during this review.

## Fixed

- **Report example accepts a negative limit** (`examples/report.wlo:38`):
  `report -n -1 app.log` printed every level but the last, because
  `levels[:-1]` slices from the end, which contradicts the option's help
  ("Show at most this many levels"). The example now rejects a negative
  `--limit` with its usage error and status 2. `report_example` in
  `tests/unit/cli_test.lua` checks the status.

## Findings

No open findings.

## Checks run

- Ran a scratch program covering `--s=`, `--n=`, `--n +5`, `-s=x`, `--=x`,
  `--help=x`, `-5`, an option value of `--`, negative int and large float
  defaults in help, raising and catching `cli.UsageError` as `Exception`, and
  `terminal.isatty` on a closed handle. Each result matched the plan and spec.
- Ran `examples/report.wlo` with `-n -1` (reproduced the bug, then confirmed
  the fix), `-n 0`, an invalid `--sort`, a missing file, and blank input lines.
- `tests/run.lua tests/unit/cli_test.lua`: 30 passed, 0 failed.

## Verdict

The implementation matches the plan and the §14 spec text. One example bug
was fixed. No findings remain open.
