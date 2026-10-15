# Tests and completion

## Goal

Close the remaining gaps between the test suite and willow.md §11, and finish
the first slice's completion criteria:

- program tests for the runtime cases not yet covered;
- CLI usage in `README.md`;
- a record of the platforms where `make test` has passed.

Most §11 cases already have tests from earlier milestones, so this change adds
only the missing ones.

## Related code

- `tests/unit/lexer_test.lua`, `parser_test.lua`, `bind_test.lua`,
  `check_test.lua` — already cover every lexer/parser and static case listed in
  `agents/todo.md`, including whole-function shadowing (`bind_test.lua`),
  missing returns after `while True`, and loop transfer misuse
  (`check_test.lua`).
- `tests/programs/` — already covers the `-0.0` cases and string round trips
  (`print_values`), `None == None` order and short-circuit effects
  (`evaluation_order`), `continue` with temporaries and recursion
  (`control_flow`), multiplication overflow, and column-accurate frames on a
  multi-call line and a return-call site (`overflow_frames`).
  `sums.wlo`/`sums.out` duplicate `examples/sums.wlo`.
- `tests/unit/cli_test.lua` — already covers `check` not executing, `run`
  matching built output, preserved output on invalid source, path, symlink, and
  hardlink aliasing, paths with spaces, and standalone output outside the
  checkout.
- `README.md` — setup only; no CLI usage yet.

## Decisions

- **Missing runtime cases become program tests**, one `.wlo` each with exact
  `.out`/`.err`:
  - `integer_boundaries`: arithmetic that lands exactly on
    `9007199254740991` and `-9007199254740991` without failing, including
    negation of each bound.
  - `overflow_add` and `overflow_sub`: each operation overflowing by one, with
    the frame at the operator. Negation cannot overflow, since the range is
    symmetric.
  - `argument_order_on_failure`: `show(say(1), boom(2), say(3))` prints `1`,
    fails inside `boom`, and never prints `3`.
  - `many_temporaries`: one function using more than 200 temporaries:
    - 250 statements `total = total + step(0)`;
    - a 250-term sum of calls;
    - a 250-deep nested call.

    The file is generated once with a short script and committed as plain
    source.
  - `type_error_prevents_execution`: `main` prints before calling a function
    whose body has a type error. Only the diagnostic appears, with no stdout.
- **`tests/programs/sums.wlo` and `sums.out` are removed**, since they copy
  `examples/sums.wlo`.
- **README.**
  - A `Usage` section covers:
    - running `./willow` from the checkout, or through a symlink on `PATH`
      (the launcher follows symlinks);
    - the three commands;
    - that a built file needs only LuaJIT 2.1;
    - the exit status (0 on success, 1 on errors), with diagnostics on stderr
      and program output on stdout.
  - The Setup section names the platforms where `make test` has passed. These
    are only the ones run for this change: macOS 26 arm64 locally, and Linux
    arm64 with glibc in Docker.

## Test plan

The new tests above. Run `make test` on macOS. Then run it in a Linux arm64
container (`gcc` image) on a copy of the repository with LuaJIT rebuilt inside
it.

## Implementation plan

1. `tests/programs/`:
   - add `integer_boundaries`, `overflow_add`, `overflow_sub`,
     `argument_order_on_failure`, `many_temporaries`, and
     `type_error_prevents_execution`;
   - remove `sums.wlo` and `sums.out`.
2. `README.md`: the Usage section and the tested platforms.
3. `agents/todo.md`: check the Tests and completion milestone.
