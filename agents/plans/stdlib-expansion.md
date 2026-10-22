# Standard library expansion

Scope: the seven priority areas agreed on 2026-10-22. Implement small,
composable APIs for collections, mathematics, strings, files, bytes, randomness,
and asynchronous integration. Sets, regex, CSV, hashing/base64, date parsing,
and unrelated language features are deferred.

## Delivery and ownership

Use swarm `willow-stdlib-20261022`, Claude Code, model `claude-sonnet-5-5`,
high effort. Ten agents own separate public API areas: builtins, math, str,
bytes, fs, random, net, aio, http, and subprocess. Built-in type families count
as modules for ownership. Each agent produces one independently testable PR
against main, with its API documentation and representative tests. No agent
merges a PR. The operator collects and inspects the results.

Follow AGENTS.md: small idiomatic Lua, no frameworks or unrelated cleanup.
Preserve current behavior except the explicitly additive APIs below. Keep
existing errors and evaluation order. New functions accept named parameters
where existing module functions do. Use normal static diagnostics for bad
argument types, ValueError for invalid values, OSError for host failures,
and TimeoutError for expired timeouts.

Shared compiler files cannot be owned exclusively by module. Limit edits to
the module's declarations/checking/lowering. Do not reorganize shared tables
or introduce a universal overload framework. Use new tests/unit/stdlib_AREA_test.lua
and tests/programs/stdlib_AREA*.wlo files instead of appending every test to
check_test.lua. Runtime additions should be in a module-specific file when
substantial; register those in compiler/runtime.lua using the existing pattern.
Keep runtime/core.lua additions small: LuaJIT has a per-function local limit.
Edit only the corresponding sections of docs/spec.md; do not renumber sections.

Every agent can see this entire design. Shared-file collisions are expected to
be narrow and resolved during integration. Agents must not cherry-pick one
another, change another area's contract, or engage in repeated peer exchanges.
Report cross-area needs to the operator. Tasks below are independently buildable
on current main and must not rely on another agent's additions.

## Builtins and collections (agent builtins)

Public additions:

- abs(x): int -> int or float -> float, preserving the exact numeric type.
  Willow ints have the symmetric range +/- (2^53 - 1), so every int absolute
  value is representable, including the minimum. Do not impose a 32/64-bit
  two's-complement minimum overflow rule.
- round(x: float) -> int: nearest integer with ties to even. Nonfinite or
  out-of-range results raise ValueError. No ndigits parameter in this batch.
- min/max: support either one Iterable[T] or two T operands. T must be one
  homogeneous orderable type already accepted by sorted, including comparable
  tuples. Return T; no key/default/variadic forms. Empty iterable and NaN in
  comparison operands raise ValueError, consistent with sorted's NaN rule.
  Equal values select the first. Evaluate arguments once, left to right.
- sum(items): Iterable[int] -> int or Iterable[float] -> float. Empty input
  produces the correctly typed zero. Integer addition retains overflow checks.
- any/all(items: Iterable[bool]) -> bool, short circuit, empty False/True.
  Do not introduce implicit truthiness.
- list(items: Iterable[T]) -> list[T], materializing once in iteration order.
- enumerate(items: Iterable[T], start: int = 0) -> Iterator[tuple[int, T]].
  Lazy; counter overflow uses normal integer OverflowError.
- zip(a: Iterable[T], b: Iterable[U]) -> Iterator[tuple[T, U]], lazy,
  left-to-right advancement, stops at the shorter input. No variadic zip.
- xs.extend(items: Iterable[T]) -> None, preserving type invariance; snapshot
  input before mutation so xs.extend(xs) works and iteration failure does not
  partially extend the receiver. xs.reverse() -> None, in place.
- d.keys() -> Iterator[K], d.values() -> Iterator[V],
  d.items() -> Iterator[tuple[K, V]], in insertion order, with the existing
  dictionary iterator's structural-mutation rules.
- d.get(k, default): preserve existing one-argument V | None result. With a
  default of V return V; with None return V | None. Stored None remains a
  present value; the default is used only for an absent key. Do not broaden
  the dictionary's value type to arbitrary unrelated default types.

Own built-in registrations in compiler/stdlib.lua, list/dict and builtin
branches of compiler/check.lua and compiler/lower.lua, corresponding runtime
helpers (prefer runtime/collections.lua for substantial new helpers), and
spec sections 7 and 11. Existing builtin-as-callable adaptation must either
support a statically resolvable signature or issue a clear compile-time error;
never accept a call that generates an invalid runtime invocation.

## Math (agent math)

Keep sqrt unchanged. Add floor(x: float) -> int, ceil(x: float) -> int,
isfinite(x: float) -> bool, isnan(x: float) -> bool, isinf(x: float) -> bool,
pow(x: float, y: float) -> float, exp(x: float) -> float,
log(x: float) -> float (natural log), log10(x: float) -> float,
sin/cos/tan(x: float) -> float, asin/acos/atan(x: float) -> float,
atan2(y: float, x: float) -> float. Add read-only float values math.pi,
math.e, and math.tau through narrow compiler-provided constant support;
do not add source-language constant declarations or a general property system.

Transcendental functions follow host IEEE/libm behavior (domain errors yield
NaN, overflow may yield infinity), matching sqrt's policy. Floor/ceil reject
nonfinite and out-of-int-range results with ValueError. Keep signed zero
where floating results naturally preserve it. abs and round belong to builtins.
Own math declarations, minimal constant binding/checking/lowering, runtime/math.lua,
and the math spec subsection. Do not modify unrelated built-in call behavior.

## Strings (agent str)

Add split(sep: str | None = None, maxsplit: int = -1) and
rsplit with the same parameters; sep=None splits runs of the same six ASCII
whitespace characters strip already recognizes. Negative maxsplit is unlimited.
Explicit separators preserve empty fields and an empty separator still raises
ValueError. Use Python split/rsplit behavior for maxsplit=0 and outer whitespace.

Add splitlines(keepends: bool = False), recognizing LF, CR, and CRLF; an empty
string yields an empty list and a trailing line ending adds no empty final
line. Add lstrip()/rstrip(), removing the same ASCII whitespace as strip;
removeprefix(prefix: str)/removesuffix(suffix: str), removing at most once;
isascii(), isspace(), isdigit(), isalpha(), and isalnum(). Classification is
explicitly ASCII for this batch: digits 0-9, letters A-Z/a-z, whitespace as
strip; empty strings fail classifiers except isascii. Existing Unicode casing
and code-point indexing remain unchanged. Document this deliberate limit.

Own STRING_METHODS and string-method default binding in compiler/check.lua,
string lowering if needed, string runtime helpers, and the strings spec
subsection. No Unicode category data expansion or regex support.

## Bytes (agent bytes)

Add data.find(sub: bytes) -> int (byte offset or -1),
startswith(prefix: bytes)/endswith(suffix: bytes) -> bool,
split(sep: bytes, maxsplit: int = -1) -> list[bytes], and hex() -> str
(lowercase, two hex digits per octet). Add bytes.fromhex(text: str) -> bytes
as a narrowly scoped static constructor: allow ASCII whitespace between
complete byte pairs, accept either hex case, reject odd digits/invalid text
with ValueError. Do not add a general static-method language feature.

Empty sub/prefix/suffix behave naturally; empty split separator raises
ValueError. Splitting preserves empty fields, maxsplit=0 returns [data],
negative maxsplit is unlimited. Preserve immutability and current decode.
Own bytes method checking/lowering, narrow fromhex binding, runtime/bytes.lua,
and the bytes spec subsection. Keep APIs byte-oriented, independent of UTF-8.

## Filesystem (agent fs)

Add read_bytes(path: str) -> bytes and write_bytes(path: str, data: bytes) -> None;
copy_file(source: str, destination: str) -> None, streaming binary data, replacing
destination contents, with OSError for failures and same-file rejection. No
metadata preservation or atomic-copy promise.

Add normpath(path: str) -> str (lexical POSIX normalization, Python posixpath
semantics), abspath(path: str) -> str (cwd plus normpath),
realpath(path: str) -> str (resolve an existing path via the host, failure raises
OSError), and glob(pattern: str) -> list[str] (POSIX *, ?, [] patterns, sorted
by code point, no recursive ** extension, no matches gives []).

Add walk(path: str) -> Iterator[tuple[str, list[str], list[str]]]: yield each
visited directory, directory basenames, and other entry basenames, top down;
sort entries, do not follow symlink directories, close directory handles before
yielding. The directory lists are snapshots, not a pruning API. Errors propagate.

Add temp_file(prefix: str = "willow-", directory: str | None = None) -> str
and temp_dir with the same parameters. Atomically create a unique empty file
(closed before return) or directory, respectively, using host temp creation.
Default parent is TMPDIR if set and nonempty, otherwise /tmp. Prefix must be
one filename component. The caller owns cleanup with remove/rmdir. No invented
resource framework or automatic recursive deletion.

Own fs declarations, filesystem portions of runtime/host.lua or runtime/fs.lua,
and the fs spec subsection. Do not refactor process or socket helpers.

## Randomness (agent random)

Add a random module with generator(seed: int) -> Random. Random is a native
stateful handle with random() -> float in [0,1), randint(a: int, b: int) -> int
inclusive, choice[T](items: list[T]) -> T, and shuffle[T](items: list[T]) -> None.
Use a small deterministic 32-bit PRNG with independent state per handle;
repeatable seed behavior within this version, no promise of Python sequence
compatibility. Use rejection sampling for integer ranges, including the full
int range; reject a>b and empty choice with ValueError. Shuffle in place using
Fisher-Yates. Do not use or reseed Lua's global math.random.

Add secure_bytes(size: int) -> bytes using the OS random source, independently
of generators; negative sizes raise ValueError, host failures raise OSError.
Do not implement cryptography or describe the PRNG as secure. /dev/urandom with
proper complete reads/cleanup is sufficient for macOS and Linux.

Own random registration/types, runtime/random.lua and registration, a new random
subsection in spec section 14. Generic native methods already have typevar
support; use it instead of expanding unrelated global builtin inference.

## Buffered networking (agent net)

Add net.reader(connection: net.Connection) -> net.Reader. The native Reader
owns the connection, supports close/enter/exit, and has:

- read_exactly(size: int, timeout: float | None = None) -> bytes: exactly size
  bytes; zero returns empty; negative size is ValueError; early EOF raises
  OSError with a clear unexpected-EOF message.
- read_until(separator: bytes, max_bytes: int = 1048576,
  timeout: float | None = None) -> bytes: return through and including the
  delimiter, retaining excess bytes for the next call. EOF returns the remaining
  bytes, or empty if none. Empty delimiter/nonpositive max_bytes is ValueError;
  reaching the limit without a complete delimiter raises ValueError.

Use one monotonic deadline for the whole call, not a fresh timeout for each
recv. Preserve buffered bytes after timeout or size-limit errors. A delimiter
ending exactly at max_bytes succeeds. Document that callers transfer read
ownership and must not interleave raw recv calls. Use existing socket runtime
operations; do not depend on the bytes agent's methods or change existing recv.
Own only net declarations and new runtime/net_reader.lua (plus registration),
and the net spec subsection. Async readers are deferred; aio owns scheduling.

## Async coordination (agent aio)

Add aio.semaphore(value: int = 1) -> Semaphore, with
acquire() -> Coroutine[None] and release() -> None. Nonpositive initial values
raise ValueError. Waiting acquires are FIFO. Cancellation removes a waiter;
if cancellation races a permit handoff, restore/transfer the permit so it is
not leaked. Release without a matching acquire raises ValueError; the bound is
the initial count. Scope with explicit try/finally and release for now; do not
invent async context-manager protocol support. Acquire is an await checkpoint
even when a permit is immediately available. Respect existing deadlock detection.

Own aio declarations and runtime/aio.lua. HTTP and subprocess will use the
existing aio_sleep/aio_wait_fd/checkpoint helpers independently; do not redesign
those interfaces or assume their PRs are available. Add representative fairness,
cancellation, misuse and concurrent-task tests, and document the API in aio.

## Async HTTP (agent http)

Add http.request_async and http.download_async with the exact same parameters,
defaults, responses and errors as request/download, returning Coroutine[Response]
and Coroutine[Download]. Preserve redirects, deadlines, TLS verification, header
rules and download cleanup. Cancellation cleans curl handles, callbacks and
partial downloads according to the synchronous API's cleanup policy.

Use libcurl multi to advance nonblocking transfers and yield to the existing
aio scheduler between progress steps. Never yield from a C callback and never
wrap blocking curl_easy_perform in a coroutine. A bounded cooperative timer
(e.g. at most 10 ms between progress checks, respecting curl/deadline timers)
is acceptable for this first version; no new general event-loop extension
framework. State resolver limitations honestly if system libcurl can perform
blocking DNS. Avoid requiring the aio semaphore PR or any other agent's work.

Own runtime/http.lua, http declarations, optional-runtime dependency wiring,
tests/unit/stdlib_http_test.lua and dedicated local HTTP fixture tests, and
http documentation. Test observable overlap with a sleeping task and delayed
local responses, plus cancellation cleanup. No public network in tests.

## Async subprocess (agent subprocess)

Add subprocess.run_async with run's exact parameters/defaults, returning
Coroutine[Result]. Add Process.wait_async(timeout: float | None = None)
-> Coroutine[int]. Keep synchronous APIs and result conventions unchanged.

run_async must concurrently drain stdout/stderr and write input without blocking
the event loop, including large input/output. Use existing spawn/nonblocking
pipe primitives and cooperative waits; bounded timer checks (at most 10 ms)
are acceptable for process exit/multiple descriptors in the first version.
Do not introduce threads, fork a Lua VM, or require a new scheduler framework.
On run_async timeout or cancellation, kill and reap the owned child, close
pipes, then propagate the original error/cancellation. wait_async cancellation
or timeout leaves the explicitly spawned process owned by the caller, consistent
with wait; do not terminate it implicitly. Every timeout is a whole-operation
monotonic deadline. Preserve run's existing descendant-pipe policy.

Own process parts of runtime/host.lua or a narrowly extracted runtime/process.lua,
subprocess declarations and runtime dependency wiring, and subprocess docs.
Do not refactor filesystem or net code. Test timer overlap, simultaneous large
stdin/stdout/stderr, exit status, timeout and cancellation cleanup locally.

## Validation and completion

The existing gnat-agent image built current main and passed make test on Linux:
387 passed, 0 failed. No custom Dockerfile is needed. Each agent must run focused
observable tests during work and make test before delivery. Use compiler/runtime
embedding and build/run checks where a new optional runtime or compiler constant
could otherwise break standalone output. Do not run benchmark suites or add
exhaustive tests. The host operator will inspect PRs and, where warranted, test
the combined result on macOS in a scratch clone. Review findings are reported
to the user; the user's instructions prohibit automatic review fixes or commits.

Final agent reply: PR URL, concise API summary, test results, and any deviations,
known limitations or blockers. PR descriptions must state behavior and validation,
not swarm process. Do not merge, close other PRs, or modify main. If a contract
cannot be implemented cleanly, report the concrete obstacle instead of silently
reducing scope. The operator will file public gnat feedback after the run.
