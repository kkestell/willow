# Benchmark optimizations

## Scope and method

The four Willow benchmarks in `benchmarks/` were investigated for optimization
opportunities. Each hypothesis came from reading the generated Lua in
`benchmarks/build/` and LuaJIT's `-jv` trace log. Three Ox agents on cheap
OpenRouter models (deepseek-v4.1-flash, glm-5.3-flash, mimo-v2.6-flash) tested
the hypotheses, one each, in their own clones, with `make test` and
`python3 benchmarks/run.py`. Their numbers were taken in Linux containers that
shared one machine, so they are only indicative. The table below was measured
on the host afterwards.

The two confirmed changes are in the working tree, uncommitted: deepseek's loop
change in `compiler/lower.lua`, `compiler/emit.lua`, `runtime/core.lua`, and
`tests/unit/lower_test.lua`, and glm's division change in `runtime/core.lua`
and `tests/programs/integer_boundaries.*`. With both applied, `make test`
passes with 381 passed and 0 failed.

Gaps:

- The run was stopped early. glm never wrote its final report, and mimo's
  second task (binary-trees) stopped while it was still prototyping.
- Linux was not measured on the host. The containers run arm64 Linux.
- The patches were read and their test additions were checked against
  CPython. They have not had a full `/kreview`.

## Results

Willow only, in seconds of wall-clock time, best of 3 runs, on an Apple M4 Max.
The four configurations ran back to back.

| Benchmark (size)      | main | loops | divmod | both | Speedup |
| --------------------- | ---: | ----: | -----: | ---: | ------: |
| n-body (5,000,000)    | 5.08 |  0.41 |   4.95 | 0.42 |     12x |
| spectral-norm (2,000) | 8.08 |  7.82 |   0.91 | 0.77 |     10x |
| fannkuch-redux (10)   | 2.21 |  0.51 |   1.96 | 0.31 |    7.2x |
| binary-trees (18)     | 3.11 |  3.20 |   3.22 | 3.33 |      1x |

The README's hand-written LuaJIT baselines are 0.32, 0.12, 0.22, and 2.72 s.

## Summary

| ID | Verdict   | Title                                                         |
| -- | --------- | ------------------------------------------------------------- |
| H1 | Confirmed | Loop iterator closures keep LuaJIT from compiling loops       |
| H2 | Confirmed | `math.fmod` in integer `//` and `%` breaks traces             |
| H3 | Refuted   | Top-level functions are globals                               |
| H4 | Open      | The `__wlo_record` tag makes binary-trees' nodes expensive    |
| F1 | Bug       | `__wlo_int_mod` assigns the global `_`                        |

## H1. Loop iterator closures keep LuaJIT from compiling loops

Confirmed · deepseek

`for` over `range(...)` or a list compiled to a generic `for` driven by a
closure from `__wlo_range` or `__wlo_list_items`. LuaJIT 2.1 cannot compile
closure creation, which is the FNEW bytecode, so `-jv` showed `NYI: bytecode
FNEW` aborts in every benchmark. Any loop with an inner loop ran interpreted.

The change emits a numeric `for` for `range` loops and an indexed `while` loop
for list loops. The `while` loop rereads `list.n` at each step, as the
iterator did. Other iterables keep the iterator. The zero-step `ValueError` is
raised by a new `__wlo_range_step` at the `range` call's site before the loop,
and is skipped for a nonzero literal step. After the change, `-jv` reports no
FNEW aborts. deepseek checked that range arguments are evaluated once and in
order. It also checked variable, negative, and zero steps, lists that grow or
shrink during iteration, tuple targets, and break, continue, and try inside
loops.

## H2. `math.fmod` in integer `//` and `%` breaks traces

Confirmed · glm

`__wlo_int_floordiv` and `__wlo_int_mod` went through `__wlo_divmod`, which
calls `math.fmod`. LuaJIT does not compile `math.fmod`, so each division
stitched the trace. spectral-norm's matrix entry function divides by 2 in the
innermost loop. deepseek's profile put 80% of samples in `__wlo_divmod`.

The change computes `div = math.floor(a / b)` and `mod = a - div * b`, and falls
back to `__wlo_divmod` when `|div * b| > 2^52`. Below that bound, the rounding
error of `a / b` is smaller than the quotient's distance from the nearest
integer, so the floor is exact, and the product and difference are exact
integers. The float `//` and `%` paths are unchanged. glm added 18 cases near
the 53-bit limits to `tests/programs/integer_boundaries.wlo`, and their
expected output matches CPython.

## H3. Top-level functions are globals

Refuted · mimo

`emit.lua` already forward-declares the entry module's top-level functions as
locals. The `function name(...)` lines that look global assign those locals.
As a negative control, mimo forced the functions to be real globals, and every
benchmark stayed within noise. LuaJIT guards global lookups on the trace, so
they cost little once the code is compiled.

## H4. The `__wlo_record` tag makes binary-trees' nodes expensive

Open · mimo (stopped before reporting)

H1 and H2 do not affect binary-trees. mimo edited the generated Lua by hand and
timed each change at size 18:

| Variant                              | Seconds |
| ------------------------------------ | ------: |
| As generated                         |    3.31 |
| Without `__wlo_record = "Node"`      |    2.13 |
| Plain `+` instead of `__wlo_add`     |    3.20 |
| Hand-written `benchmarks/lua`        |    2.85 |

The record tag accounts for the whole gap and more. It is the third key in a
two-field node table, which presumably doubles the hash part allocated for
every node. The tag is read in only three runtime places: `__wlo_isinstance`,
`__wlo_isinstance_type`, and `__wlo_tag`. mimo's first prototype moved the tag
into a shared metatable with `__index`, and binary-trees took 3.70 s, slower
than with the tag. That cost comes from `setmetatable` itself. A
representation that keeps the tag out of the instance without calling
`setmetatable` on every construction has not been tried.

## F1. `__wlo_int_mod` assigns the global `_`

Bug · `runtime/core.lua` (glm's change)

The fallback branch reads `_, mod = __wlo_divmod(a, b, site)` without a local
`_`, so it writes a global. It only runs above 2^52, but it should declare `_`
as a local or call `select(2, ...)`.

## Next hypotheses

These come from the generated code and have not been measured.

- spectral-norm is still 6x slower than the hand-written Lua. Its inner loop
  makes four overflow-checked integer operations through `__wlo_add` and
  `__wlo_mul` per entry, plus an integer division.
- n-body is within 1.3x of the hand-written Lua. The remaining per-operation
  costs are `__wlo_float_mul`'s signed-zero check and `__wlo_list_index`'s
  negative-index normalization.
