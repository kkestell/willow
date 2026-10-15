# Tests and completion review

## Scope and coverage

Reviewed the staged Tests and completion changes against `agents/plans/2026-10-14-009-tests-and-completion.md`, `willow.md` §4, §5, §8–§11, and `AGENTS.md`: the six new program tests in `tests/programs/`, the removal of `tests/programs/sums.*`, `README.md`, and `agents/todo.md`. Also read the code these tests depend on: `tests/run.lua`, the launcher, the integer helpers in `runtime/core.lua`, the generated Lua for `many_temporaries.wlo`, and the existing unit and program tests that the newly checked todo items rely on.

`many_temporaries.wlo` produces 750 temporary values in `main`. Lowering recycles them into two Lua locals, so the test guards against one local per temporary, which would exceed LuaJIT's 200-local limit. A separate limit remains outside this change. All locals and temporaries are declared at function entry, so a function whose named locals and deepest live temporaries together exceed 200 fails to load and is reported as an internal compiler error. Scratch runs hit this with a right-nested sum `step(0) + (step(0) + (...))` of 201 terms (200 terms run) and with 201 named locals. Both need more than 200 levels of nesting or more than 200 variables in one function. Under `AGENTS.md` these are pathological programs, so this is not a finding.

The new tests ran on macOS arm64 only. The Linux results in `README.md` come from the implementer's container run.

## Fixed

None.

## Findings

No open findings.

## Checks run

- `vendor/luajit/src/luajit tests/run.lua` on the six new program tests: `6 passed, 0 failed`.
- Compared each `.err` column with its source: the overflow frames point at the `+`, `-`, and `*` operators, the caller frame points at the `boom` call, and the type error points at the string literal.
- Read `__wlo_check` in `runtime/core.lua`: it rejects values strictly above `9007199254740991` or below `-9007199254740991`, so `integer_boundaries`, `overflow_add`, and `overflow_sub` pin both sides of each bound.
- Built `many_temporaries.wlo` and inspected `main`: 250 statements, a 250-term sum, and a 250-deep call, using `__wlo_t1` and `__wlo_t2`.
- Scratch right-nested sums of 150, 190, 198, 199, 200, 201, and 250 terms, and functions with 199, 200, and 201 named locals: up to 200 run correctly; 201 and above exit 1 with an internal compiler error.
- `grep` for references to the removed `tests/programs/sums.*`: none.
- `git diff --cached --check`: clean.

## Verdict

The new program tests cover the §11 runtime cases that were missing, with exact output and source locations. `README.md` documents CLI usage and the platforms where `make test` has passed. No findings remain open.
