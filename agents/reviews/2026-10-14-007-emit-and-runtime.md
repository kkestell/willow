# Emit and runtime review

## Scope and coverage

Reviewed the staged Emit and runtime changes against `agents/plans/2026-10-14-007-emit-and-runtime.md`, `willow.md` §4, §5, §7–§10, and `AGENTS.md`: `compiler/emit.lua`, `runtime/core.lua`, `tests/unit/emit_test.lua`, the six new program tests in `tests/programs/`, and `agents/todo.md`. Also read the code emit depends on (`compiler/lower.lua` node shapes, `compiler/bind.lua` call resolution, the lexer's identifier rule) and its callers in `compiler/cli.lua` and `tests/run.lua`.

Three details differ from the plan, and all three are in scope:

- A loop with a `continue` emits its body inside `do ... end` ahead of the `::__wlo_continue_N::` label. LuaJIT accepts `break` and `return` only as the last statement of a block.
- On stack overflow, the innermost frame is the recursing function's header line, which LuaJIT reports at function entry. The unit test asserts that location.
- The two launcher tests pass an absolute temporary `.wlo` path to `willow run` and do not run it from a fresh directory.

The spec requires forward-declaring every user function as a local at file top, so LuaJIT's per-function limits (200 locals and 60 upvalues) also limit programs. A program with more than 184 functions, or a function that calls more than 60 distinct functions, fails to load and is reported as an internal compiler error. This comes from the specified layout, not from the implementation, so it is not a finding here. Checks ran on macOS only.

## Fixed

None.

## Findings

No open findings.

## Checks run

- `make test`: `78 passed, 0 failed`.
- `git diff --cached --check`: clean.
- Inspected emitted Lua for `control_flow`, `evaluation_order`, `lua_keyword_names`, and `sums`. Checked forward declarations, mangling, the function-level `local` lines, `elseif` chains, `while true` with setup, `do ... end` before `continue` labels, one call per line, site order, and a source map that covers only translated lines.
- Scratch programs run through `willow run`:
  - unbounded recursion with and without trailing arithmetic: 20 frames plus `... N more frames`, exit 1, about 0.1 s;
  - overflow after JIT warm-up in a hot loop and inside hot recursion: error and caller frames at the correct columns;
  - `pass`-only bodies, `elif`/`else` with nested `if`, `continue` as a whole branch, `while False: continue`, `not True == False`, `None == None`, `-0 == 0`: correct output;
  - `print` with stdout closed: `cannot write output: Bad file descriptor` at the `print` site, exit 1.
- LuaJIT `loadstring` on `break ::x::` and `return 1 ::x::`: both rejected, which confirms why the loop body is wrapped.
- Scratch programs with 184 functions, 185 functions, and a function calling 61 functions: the first runs; the other two fail to load at LuaJIT's local and upvalue limits.

## Verdict

Emit and runtime match the plan and the spec's layout, hygiene, single-call, source-map, checked-arithmetic, printing, and failure-report requirements. No findings. Ready to commit.
