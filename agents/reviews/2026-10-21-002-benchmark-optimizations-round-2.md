# Benchmark optimizations, round 2

## Scope and method

A second round on the four benchmarks in `benchmarks/`, after the loop and
integer division changes of the previous round were merged. Each hypothesis
came from the generated Lua in `benchmarks/build/`, LuaJIT's `-jv` trace log,
`-jp=fl` profiles, and `-jdump=i` IR dumps of the hot loop traces, and was
first timed by hand-editing the generated Lua on the host. Four Claude Code
agents (claude-sonnet-5-5, high effort) tested one hypothesis each in their own
clones, with `make test` and `python3 benchmarks/run.py`, and delivered a patch
and a report. Their numbers were taken in arm64 Linux containers that shared
one machine and are only indicative; the tables below were measured on the
host afterwards.

Every kept patch was reviewed on the host. The combined change passes
`make test` with 385 passed and 0 failed. The new tests' expected outputs
were checked against CPython.

Gaps:

- Linux was not measured on the host, and no x64 (non-dual-number) LuaJIT
  build was run. H5's reasoning for that build is in its section.
- `tests/unit/cli_test.lua` `broken_pipes_are_errors` failed once in several
  runs for two agents on unmodified main, so a single `make test` failure
  there is not evidence against a change.

## Results

Willow only, in seconds of wall-clock time, best of 3 runs, on an Apple M4 Max,
with the swarm down. Each column applies one patch to main; the configurations
ran back to back in this order.

| Benchmark (size)      | main |   H7 |   H6 |   H4 |   H5 | H5+H10 |   H9 |  All | Speedup |
| --------------------- | ---: | ---: | ---: | ---: | ---: | -----: | ---: | ---: | ------: |
| n-body (5,000,000)    | 0.42 | 0.42 | 0.41 | 0.40 | 0.40 |   0.39 | 0.39 | 0.37 |    1.1x |
| spectral-norm (2,000) | 0.77 | 0.74 | 0.76 | 0.76 | 0.62 |   0.55 | 0.81 | 0.50 |    1.6x |
| fannkuch-redux (10)   | 0.31 | 0.29 | 0.31 | 0.30 | 0.30 |   0.28 | 0.31 | 0.28 |    1.1x |
| binary-trees (18)     | 3.51 | 3.18 | 2.94 | 2.77 | 3.35 |   3.17 | 3.15 | 2.21 |    1.6x |

The hand-written Lua baselines in the README are 0.32, 0.12, 0.22, and 2.72 s.
binary-trees is now faster than the hand-written Lua, whose nodes are two-key
hash tables. binary-trees varies by up to 10% between runs; its single-patch
columns are indicative.

With all patches but H9 applied, n-body took 0.385 s and the others were
unchanged, so H9 was kept.

## Summary

| ID  | Verdict      | Title                                                          |
| --- | ------------ | -------------------------------------------------------------- |
| H4  | Confirmed    | The record tag belongs in the table's array part               |
| H5  | Confirmed    | `bit.tobit` lets the JIT skip the overflow check for int32     |
| H6  | Confirmed    | Literal `None` fields can be left out of constructors          |
| H7  | Confirmed    | `local function` makes top-level functions constant upvalues   |
| H8  | Inconclusive | Static `len` and non-negative list indexes                     |
| H9  | Confirmed    | A branch-free signed-zero float multiply                       |
| H10 | Confirmed    | Library functions bound as runtime locals                      |

## H4. The record tag belongs in the table's array part

Confirmed · cat

The previous round found that removing `__wlo_record = "Node"` from
binary-trees' nodes saved about a third of its time: the tag was a third hash
key, and LuaJIT rounds a constructor's hash part up to a power of two, so a
two-field record paid for four slots. Two representations were timed by hand
first. A shared metatable holding the tag, without `__index`, gave nothing:
`setmetatable` per construction cost as much as the key. Storing the tag as
the first array element, `{ "Node", left = x, right = y }`, took binary-trees
from 3.33 s to 2.33 s together with H6.

The change emits records that way and makes the three readers of the tag,
`__wlo_isinstance`, `__wlo_isinstance_type`, and `__wlo_tag`, read `[1]` after
testing for exceptions, enums, float boxes, bytes, tuples, and lists, since a
list `["Node"]` also has a string at `[1]`. Every record the runtime builds
(range, iterator, generator, coroutine, and the io, fs, subprocess, net, http,
aio, and cli records) uses the same representation. Exceptions keep
`__wlo_class`. Nothing enumerates a record's fields with `pairs`. A record
field named `n` would make a record look like a list, so the emitter names
that field `n_` in generated Lua; `tests/programs/record_tags.wlo` sends a
`Node` with a field `n`, a list, a tuple, and a dict through one union.

## H5. `bit.tobit` lets the JIT skip the overflow check for int32

Confirmed · ant

The IR of spectral-norm's inner loop showed each `__wlo_add` as an `ADDOV`
guard followed by a conversion to double, two range compares, and a zero test:
five operations where the hand-written Lua has one. The range test cannot fail
for an int32 result, and `bit.tobit(value) == value` holds exactly for those,
so `__wlo_check` now runs its NaN and range test only when
`__wlo_tobit(value) ~= value`. The JIT records `tobit` of an overflow-checked
add as a wrapping add plus a compare, so the int32 path costs three
operations rather than one; comparing against the int32 limits instead does
not fold at all and was slower when tried by hand.

The -0.0 normalization moved to the callers that need it. A sum or difference
of two integers is never -0.0, so `__wlo_add` and `__wlo_sub` have none.
`__wlo_mul` and `__wlo_neg` normalize unconditionally, because `0 * -3e10` and
`-(0)` produce -0.0 and `tobit(-0.0) == -0.0` is true. `__wlo_int_floordiv`
and `__wlo_int_mod` skip the `div * b` exactness test when `a` is int32:
|div * b| <= |a| + |b|, and when |b| >= 2^31 the quotient is within 1 of zero,
so the floor is exact. On a non-dual-number build every number is a double
and `tobit(v) == v` means |v| < 2^31, which cannot overflow, so the reasoning
holds there too. `tests/programs/int32_boundaries.wlo` covers the int32 limits,
zero products, and int32 numerators with divisors beyond 2^31 of both signs;
its expected output matches CPython.

## H6. Literal `None` fields can be left out of constructors

Confirmed · bee

binary-trees' leaf constructor was `{ __wlo_record = "Node", left = nil,
right = nil }`. LuaJIT sizes the hash part for all three keys although two
values are nil. The emitter now omits a field whose lowered value is a literal
`None`, whether passed or taken from a class default; reading it gives `nil`
as before, and other arguments are still evaluated in order. A record whose
omitted field is assigned later pays a hash resize on the first assignment.
`tests/programs/record_none_fields.wlo` covers both sources of `None`, later
assignment, and an argument with side effects.

## H7. `local function` makes top-level functions constant upvalues

Confirmed · dog

The emitter forward-declared a program's functions as locals and assigned them
with `function name(...)`. LuaJIT marks a local that is assigned after its
declaration as mutable, so every call from another function loaded the upvalue
and guarded it on each loop iteration: `UREFO`, `UGT`, `ULOAD`, and `EQ` in
spectral-norm's inner loop. A function that no earlier function names is now
emitted as `local function name(...)`, whose binding the JIT folds to a
constant; a function named before its definition, such as one half of a
mutually recursive pair, keeps the forward declaration. Function order is
unchanged, and the declaration line is reserved first so source locations do
not shift. After the change the loop has no `UREFO` or `ULOAD`.

## H8. Static `len` and non-negative list indexes

Inconclusive · dog

Profiles put about 40% of fannkuch-redux in list indexing, and n-body calls
`__wlo_len(bodies)` on every `advance`. Hand edits gave about 3% each for
emitting `list.n` for a list-typed `len` and for skipping the negative-index
normalization when the index is a non-negative literal or a `range` loop
variable with non-negative literal bounds. dog measured 0 to 3%, within the
container's noise. The patch was not kept: the index variant adds about 25
lines of lowering for at most 2%, and the `len` variant emits a field named
`n`, which H4 now renames.

## H9. A branch-free signed-zero float multiply

Confirmed · bee

`__wlo_float_mul` restored the sign of a zero product with a test on the
result, which was one guard per multiply, twelve per body pair in n-body's
loop and the only work there that the hand-written Lua does not do. It now
returns `(a + -0.0) * (b + -0.0)`: adding -0.0 leaves every double unchanged
and converts an integer-valued operand to the double of the same value and
sign, so the product is IEEE's. LuaJIT does not fold the additions, so each
guard became an add. Alone the change slowed spectral-norm by about 4% in the
container and on the host; with the other patches applied the difference was
within noise and n-body kept its gain, so it was kept. Eleven products with
signed zeros, infinities, and large values were added to
`tests/programs/floats.wlo`.

## H10. Library functions bound as runtime locals

Confirmed · ant

The runtime called `math.floor`, `math.sqrt`, `type`, `math.min`, and
`math.max` by global lookup. In a trace each call site is a chain of guards on
the environment, the library table, and the function unless hoisted out of a
loop. They are now bound once at the top of `runtime/core.lua`, next to
`__wlo_tobit`, and `__wlo_sqrt` is `math.sqrt` itself. The n-body dump lost
its `"math"` and `"sqrt"` lookups and 12% of its IR instructions.

## Measured and not adopted

- The shared-metatable tag, see H4.
- Gating `__wlo_check` on the operands rather than the result,
  `tobit(a) == a and tobit(b) == b`, folds completely for loads and loop
  variables but not for chained arithmetic; it was 2% faster than H5 on
  spectral-norm by hand, within noise.
- `collectgarbage("setpause", 400)` took binary-trees from 2.20 s to 2.02 s
  with H4 and H6 applied, at 474 MB resident instead of 319 MB. It is a
  memory trade-off rather than a fix, so it was left alone.

## Next hypotheses

- spectral-norm is still 4x slower than the hand-written Lua. Its inner loop
  now costs three JIT operations per integer operation instead of one, from
  the `tobit` compare, plus the zero-divisor and index guards. Nothing cheaper
  that folds for both int32 and double results was found.
- n-body, fannkuch-redux, and binary-trees are within 1.3x of, or faster than,
  the hand-written Lua. What remains is the index bounds guards and the
  zero-divisor guard in `__wlo_div`.
