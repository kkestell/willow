# Library keyword arguments

## Plan

`agents/plans/2026-10-19-006-library-keyword-arguments.md`

## Summary

String, list, and dict methods with parameters and `sys.eprint` accept keyword
arguments by their documented names, `bytes` is positional-only, and `frame`
in `banner.wlo` takes keyword-only `width` and `border`. The plan's goal is
met.

## Decisions

- `sys.eprint(value=...)` is tested in `tests/programs/eprint_values.wlo`,
  which already checks stderr, rather than in `named_arguments.wlo`.

## Checks run

- `make test` — 286 passed, 0 failed.

## Manual verification

1. The banner example, including its keyword call to `frame`, still prints
   both expected frames.

   ```sh
   ./willow run examples/stdlib/banner.wlo --upper --border=# --width=10 hello world
   ```

   A `#` frame around `HELLO WORLD`.
