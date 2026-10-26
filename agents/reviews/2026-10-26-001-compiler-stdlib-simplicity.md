# Compiler and standard-library review

## Scope and coverage

Reviewed the compiler and standard library from the initially clean tree at
`5835672`, against `docs/spec.md` and the repository's simplicity and bootstrap
requirements. Separate passes covered the loading/binding/type-checking/emission
pipeline, library parsing and collection code, resource and async state handling,
and duplication. Suspected findings were deduplicated and checked against callers,
requirements, and existing tests before fixing them.

Detailed traces covered source-library imports and shadowing, native types and
constants, recursive aliases and substitution, flow-state invalidation, exception
and context-manager cleanup, numeric emission, seeded random state, and CLI help.
Read the associated compiler drivers, tests, runtime helpers, and bootstrap build
commands where needed. All four findings were classified `Trivial` before fixing:
none required a new behavior, API, or design decision.

Gaps:

- No subagent facility was available. These were separate passes by one reviewer,
  not independent reviewers returning messages.
- The compiler pass was architectural with targeted deep traces, not an exhaustive
  line-by-line audit of every checker and emitter branch. The review does not
  establish the absence of other defects.
- Stage 0 and the core runtime were dependency context, not separate full reviews.
- Validation covered macOS arm64 and Linux arm64, not Linux amd64. Performance
  measurement was limited to the random-generator reproduction below.

Locations below refer to the fixed tree. Evidence explicitly identified as
pre-review refers to `5835672`.

## Summary

| ID | Severity | Category | Fix | Title |
| -- | -------- | -------- | --- | ----- |
| F1 | High | Correctness | Fixed | Async groups hide assignments from flow analysis |
| F2 | Medium | Architecture | Fixed | Unreachable compiler-provided modules retain a second module model |
| F3 | Medium | Performance | Fixed | Random generation emulates supported bit operations |
| F4 | Low | Simplicity | Fixed | CLI help repeats scalar conversion dispatch |

## F1. Async groups hide assignments from flow analysis

High · Correctness · Fixed · `compiler/check.wlo:2126`

`assigned_symbols` descended through plain `with` blocks but omitted
`ast.AsyncWith`. Its callers use that scan to remove narrowing for variables
assigned inside loops and to establish exception-handler entry types. An
assignment inside a task-group block was therefore invisible at those boundaries.
The checker could accept arithmetic on a value that becomes `none`, and generated
code could dereference that value as a boxed integer.

### Evidence

The program now in `tests/programs/group_loop_assignment.wlo` passed both
`check` and `build` before the fix. Running its built executable terminated with
SIGSEGV (status 139). It initializes `value: int | none` to 1, uses `value + 1`
in a two-iteration loop, and assigns `none` inside an `async with` in that loop.
The second iteration no longer has the type assumed for the arithmetic.

The shared scanner also feeds `forget_narrowing` for `try` bodies. Tracing that
caller showed the same omission preserved the initial `int` type in a handler
after assignment to `none` inside a task group. Both cases now produce the
expected source-level `int | none` arithmetic diagnostic. The existing loop
narrowing rule in spec §9 already requires this; no language change was needed.

### Fix

Traverse an async group's target, when present, and its body in
`assigned_symbols`, following the existing plain-context-manager traversal.
Added negative conformance cases for a loop and an exception handler, each with
its expected diagnostic. Existing valid group-flow tests remain unchanged.

## F2. Unreachable compiler-provided modules retain a second module model

Medium · Architecture · Fixed · `compiler/bind.wlo:246`

The compiler retained separate records, import maps, member lookup, alias
resolution, class builders, and host-call branches for modules defined by
compiler tables rather than source. That model had no modules left. It made
changes to imports, aliases, and native classes require reasoning about a second,
unreachable representation and left a duplicate `io.File` signature disconnected
from the implementation in `lib/io.wlo`.

### Evidence

Pre-review `stdlib.modules()` at `compiler/stdlib.wlo:316` returned an empty map,
and `loader.is_stdlib()` always returned false. The binder's provided-module map
came only from that empty map. Repository-wide reference searches showed that
the old module and `io.File` builder functions had no live callers; the
`generic_method` wrapper only received an empty type-parameter list.

Tracing actual imports showed that library modules, aliases, classes, and float
constants come from embedded source through the ordinary AST path. `sys.eprint`
and `sys.exit` are still deliberately synthesized as built-ins by the live
source-module lookup and must be preserved. `sys.args` and the filesystem
functions instead resolve to source declarations, so their old built-in call
branches were unreachable as well.

### Fix

Removed the empty table interface, its module record and unused builders, both
provided-module maps, `ProvidedAlias`, and the unreachable lookup/type-test/host
branches. Updated the AST constructor and loader comments. Kept source-module
constant handling, native visibility, runtime protocol-dispatch methods, and the
two live `sys` intrinsics. Folded the now-unnecessary generic-method wrapper into
`native_method`.

## F3. Random generation emulates supported bit operations

Medium · Performance · Fixed · `lib/random.wlo:6`, `lib/random.wlo:21`

Every PRNG state transition called a hand-written XOR loop five times. Each loop
processed up to 32 bits through division, remainder, multiplication, and branches.
Rotation separately built a power of two in a loop. These operations added both
cognitive complexity and a measurable cost to ordinary simulation workloads,
although Willow already supports the required bitwise operations.

### Evidence

All state words are unsigned 32-bit values. XOR preserves that range, and rotation
is used with 7 or 11 bits, so the intermediate left shifts fit within Willow's
symmetric integer range. The split multiply still avoids a potentially
overflowing 32-by-32-bit product and was intentionally retained.

Built before/after probes using the corresponding embedded libraries. Their
outputs matched byte for byte: 20,000 draws plus interleaved float and full-range
integer draws from six seeds, including zero and both integer extremes. Three
runs of 500,000 draws measured 0.545–0.573 seconds before and 0.0172–0.0197 seconds
after on this macOS arm64 host (best-time ratio about 32×). This is a focused
measurement, not a general compiler benchmark.

### Fix

Replaced the XOR helper with `^` at its call sites, and expressed rotation with
shifts, a 32-bit mask, and `|`. Used right shifts for the unsigned seed-mixing
steps. Preserved the algorithm, seed handling, rejection sampling, and sequence.
Added stable float and full-range integer reference values for zero and extreme
seeds to the existing random conformance program without changing its stdout.

## F4. CLI help repeats scalar conversion dispatch

Low · Simplicity · Fixed · `lib/cli.wlo:164`

Help formatting narrowed the default through four type branches: one returned a
string unchanged and the other three called `str`. All four cases already have
exactly those semantics through Willow's scalar-union `str` conversion. The
branches duplicated conversion behavior and obscured the actual required/default
help-note logic.

### Evidence

`_Entry.default` is `str | int | float | bool`; all members support `str` and
string conversion is the identity. The existing `cli_parsing` conformance case
checks the full help text, including string, integer, float, empty, and required
option defaults.

### Fix

Replaced the type dispatch with `str(entry.default)`. Kept the surrounding help
layout, required-option handling, and empty-default behavior unchanged.

## Checks run

- Baseline random and CLI conformance programs: 2 passed, 0 failed.
- Reproduced F1 before fixing it: `check` and `build` accepted the loop program;
  its executable segfaulted with status 139.
- After rebuilding, ran the two new flow-analysis cases, `stdlib_random`,
  `cli_parsing`, and the existing `group_narrowing` and `group_flow` cases:
  6 passed, 0 failed.
- Compared before/after random-probe output with `cmp`: identical. Ran the
  three-sample timing comparison described in F3.
- Initial full-suite runs were superseded when F1 was discovered; both were
  stopped and restarted after its fix and regression cases were added.
- Final `make bootstrap-test` on macOS arm64: passed. The bootstrap/core runner
  reported 121 passed, the stage-2 runtime runner 324 passed, and normal
  conformance/command tests 203 passed, all with zero failures. Unit tests,
  compiler drivers, HTTP integration, PCRE2 loading, and fixed-point comparisons
  also completed successfully.
- Final `make bootstrap-test` on Linux arm64 using the existing
  `willow-bootstrap-arm64-main:latest` toolchain image and an isolated copy of the
  working tree: passed. The bootstrap/core runner reported 121 passed, the
  stage-2 runtime runner 324 passed, and normal conformance/command tests
  203 passed, all with zero failures. Lexer, parser, type, and binder unit tests,
  HTTP integration, PCRE2 loading, driver checks, and fixed-point comparisons
  also completed successfully.
- Inspected the source diffs and confirmed no remaining references to the removed
  provided-module API. `git diff --check` passed.

## Verdict

F1 closes a confirmed type-safety hole. F2 removes an unused module model, F3
removes costly arithmetic emulation while preserving seeded results, and F4
removes redundant formatting branches. All findings are fixed; no design
questions remain. Coverage limits above still apply.
