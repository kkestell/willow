# Review: standard library and JSON

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-15-012-standard-library-and-json.md` against `docs/spec.md` §12 and §14: `compiler/loader.lua`, `compiler/cli.lua`, `lib/json.wlo`, the new program, module, and CLI tests, and `agents/todo.md`. Also read the launcher's root resolution, the CLI's use of `root`, and the only caller of `loader.load`.

Gaps:

- Checked on macOS only; the `ENOENT` value of 2 was not run on Linux.

## Summary

No findings.

## Checks run

- `make test`: 201 passed, 0 failed.
- A scratch program outside the checkout: `\u0000` and U+007F round trips, an out-of-range integer and `-9007199254740992` parsed as floats, U+2028 dumped as it is, and a 200,000-element array (about 6.4 MB) parsed and dumped in about 2 seconds.

## Verdict

The loader fallback, CLI wiring, and `json` module match §12, §14, and the plan's decisions, and the tests cover them. Committed.
