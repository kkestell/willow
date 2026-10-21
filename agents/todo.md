# TODO

Completed slices record the implementation history. Older section numbers refer
to the specification at the time. New milestones reference `docs/spec.md`, which
owns language and library semantics.

## Async support

Implement [spec §15](../docs/spec.md#15-asynchronous-execution) and `aio` (§14)
in these slices, in order. Each task is one plan and one commit with focused
tests and `make test`. The design review and runtime prototype are in
`agents/reviews/2026-10-20-009-async-spec.md` and `agents/prototypes/async/`.

- [x] Coroutines and `await` (spec §1, §3, §5, §8, §15)
  - [x] `async def` for file-level, nested, and method declarations;
    `Coroutine[T]` annotations; `async def` protocol methods as sugar for
    `-> Coroutine[T]`; `await` at its precedence level, only in async bodies,
    and no `yield` in them; the discard rule for coroutine types and unions,
    exempting type parameters
  - [x] Each coroutine a Lua coroutine emitted like a generator body; `await`
    of a coroutine as a helper call that consumes it and runs it inline;
    `coroutine was already awaited or started`; async `main` and async
    `test_*` functions driven as the root task
- [ ] Task groups, the event loop, and cancellation (spec §10, §13, §15)
  - [x] A `poll` loop with a FIFO ready queue and a timer heap; fd waits with
    deadlines for async TCP; the deadlock check (`runtime/aio.lua`)
  - [ ] `aio.sleep`, with `sleep(0)` always suspending; async `main` and tests
    run through the loop, with the fatal deadlock report
  - [ ] `aio.task_group`, `aio.Task`, `start`, `cancel`, and `result`; group
    states and their messages; joining, admission, first-failure recording,
    and task traceback frames ending in `in task started at`
  - [ ] Cancellation: the generator cancel sentinel; a `cancelled` flag and
    parent pointer per group and a scope per task, saved and cleared around
    `finally` and resource exits; checkpoints and persistent requests;
    failure precedence over an outer request; group exits lowered through
    `lower_with`'s `Try` with an exit that absorbs or converts the departure
  - [ ] Static checking: each `await` and nested group exit as a possible
    transfer to the end of enclosing groups, carrying intervening `finally`
    effects; narrowing removed at awaits and joins
- [ ] Async TCP (spec §14, §15)
  - [x] Thread the wait function through the TCP runtime, so `aio` operations
    can suspend in place of `__wlo_wait_fd`
  - [ ] `aio.listen`, `connect`, `accept`, `recv`, `sendall`, and
    `local_port` with `net`'s semantics on nonblocking sockets; one
    unfinished operation per direction; close waking pending operations;
    the closed flag checked after every wake; wait ids so stale wakes are
    ignored; partial cancelled sends marking the connection unusable
  - [ ] An echo server example with graceful shutdown and an async test that
    drives it; tests for a failure waking an accepting body, nested cleanup,
    resource handoff, and failure precedence

## First slice

- [x] Scaffold
  - [x] `willow` launcher that locates its installation and runs `compiler/cli.lua` on `vendor/luajit/src/luajit`
  - [x] `compiler/` modules per the §9 pass pipeline (`cli`, `lexer`, `parser`, `bind`, `check`, `lower`, `emit`) plus small shared modules for spans, diagnostics, and AST nodes
  - [x] `runtime/core.lua`
  - [x] `examples/hello.wlo` and `examples/sums.wlo` (the §2 program)
  - [x] Extend `tests/run.lua` and `make test` to cover `tests/unit/` and `tests/programs/`; program tests pair a `.wlo` file with expected stdout, exit status, and diagnostics

- [x] Lexer (§3, §4)
  - [x] Validate UTF-8; accept LF and CRLF; reject bare CR anywhere, including comments and strings
  - [x] Spans with one-based line, code-point column, and byte offsets
  - [x] Indentation: four-space levels producing `INDENT`, `NEWLINE`, `DEDENT`; tabs rejected outside strings and comments; blank and comment-only lines ignored; open levels closed before `EOF`; missing final newline terminates the last line
  - [x] Newlines inside parentheses produce no `NEWLINE`, `INDENT`, or `DEDENT`
  - [x] ASCII identifiers, the reserved-word list, and reserved type names `int`, `bool`, `str`
  - [x] Integer literals: decimal only, leading zeros rejected, range checked on the digit string before conversion to a number
  - [x] String literals: single and double quotes, escapes `\\ \' \" \n \r \t`, unknown escapes rejected, physical newline rejected, non-ASCII passed through
  - [x] Operators and punctuation; unsupported tokens (`/`, `//`, `%`, `**`, `+=`, `:=`, bitwise) rejected with an unsupported-operation error
  - [x] Diagnostics shaped `file:line:col: error: message`; stop at the first error

- [x] Parser (§3, §5)
  - [x] AST nodes describing Willow with a span on every node
  - [x] File scope holds only `def`; parameter and return annotations mandatory; trailing commas allowed; annotation types limited to `int`, `bool`, `str`, `None`
  - [x] Statements: assignment, annotated assignment with required initializer, call statement, `return` with and without a value, `pass`, `break`, `continue`, `if`/`elif`/`else`, `while`; blocks require at least one statement
  - [x] Non-call expression statements rejected; chained, destructuring, augmented, and walrus assignment rejected
  - [x] Precedence levels per §5, left associative; comparison operands restricted to arithmetic level so `not a == b` parses and `a == not b` is a syntax error
  - [x] Comparison chains rejected at parse time
  - [x] Call targets are bare identifiers; `(f)(x)` rejected
  - [x] Multiline expressions inside parentheses
  - [x] Reserved words without a supported construct (`for`, `class`, `import`, `lambda`, `is`, `in`, `try`, `with`, ...) rejected explicitly

- [x] Bind (§6, §7)
  - [x] Collect all file-level signatures before bodies; duplicate function and parameter names are errors; defining `print` is an error
  - [x] Require exactly one `main() -> None`
  - [x] Per-function symbols with stable identities: parameters and every name assigned anywhere in the body are locals for the whole body, shadowing functions and `print`
  - [x] Calling a local or parameter is a "cannot call local variable" error at any position; unknown names are errors
  - [x] Record the resolved target on every call node

- [x] Check (§4, §5, §6)
  - [x] Expression types: unary `+`/`-` on `int`, `not` on `bool`, `+ - *` on `int`, `+` on `str`, `and`/`or` on `bool`, `==`/`!=` on same-typed operands of any of the four types, ordering on `int` only; conditions must be `bool`
  - [x] Calls: exact arity, argument types match parameters, result is the return type; `print` accepts one value of any of the four types and returns `None`
  - [x] Locals keep one type across all assignments; an explicit annotation checks the initializer and is allowed only on the lexically first assignment; annotating a parameter is an error
  - [x] Definite assignment: join rules after `if`/`elif`/`else`, transferring branches ignored, loop-body assignments not definite after the loop
  - [x] Control transfer: an `if` whose branches all transfer is itself a transfer; statements after a transfer are unreachable errors; non-`None` functions return on every path by structural analysis; `break`/`continue` outside a loop are errors
  - [x] Record operation types for lowering; collect independent errors; report unexpected compiler failures as internal compiler errors

- [x] Lower (§9)
  - [x] Left-to-right evaluation with explicit temporaries for operands and arguments
  - [x] Short-circuit `and`/`or` as branches
  - [x] Checked integer `+ - *` and negation as runtime helper calls carrying a site ID
  - [x] `return call()` assigns to a temporary before returning; every call yields exactly one value
  - [x] `break` and `continue` as labeled loop transfers; `print` as a built-in call

- [x] Emit and runtime (§8, §9, §10)
  - [x] Forward-declare every user function as a local at file top; mangle user names; `__wlo_` prefix for helpers, temporaries, and labels
  - [x] At most one user call or fallible helper call per generated line; temporaries recycled as function-level locals; loop body wrapped in `do ... end` ahead of the `continue` label
  - [x] String literal escaping routine with round-trip tests for escapes and non-ASCII
  - [x] Deterministic output for identical source and recorded path
  - [x] Embedded source map from Lua line to Willow `(line, column, function)`; entry invocation of `main` after all definitions
  - [x] Runtime helpers inlined into the output: checked integer ops rejecting non-finite and out-of-range results and normalizing `-0.0`; `print` formatting for all four types; write and flush failures reported as runtime errors
  - [x] Structured errors `{category, message, location}`; `xpcall` handler prints `file:line:col: error: message` plus Willow caller frames, hides runtime and wrapper frames, and wraps raw VM string errors with the innermost Willow frame

- [x] CLI (§8)
  - [x] `check`, `run`, `build -o <path>`; unknown options and extra arguments rejected; exit 0 on success and 1 otherwise; diagnostics on stderr, program output on stdout
  - [x] `run` compiles in memory and executes only after the full source checks
  - [x] `build` writes a temporary sibling, flushes, and renames atomically; a failed build leaves existing output intact
  - [x] Output paths that alias the input rejected via `ffi` `stat` device and inode comparison

- [x] Tests and completion (§11)
  - [x] Lexer/parser tests: indentation, tabs, blank and comment-only lines, bare CR, missing final newline, UTF-8, escapes, precedence, chained comparisons, parenthesized call targets, multiline calls, malformed blocks, unsupported syntax
  - [x] Static tests: inference, annotations on non-first assignments, whole-function shadowing, forward calls, mutual recursion, arity, operand types, missing returns after `while True`, definite assignment, unreachable code, incompatible branch assignments, loop transfer misuse
  - [x] Program tests: integer boundaries, overflow on each operation, `-0.0`, string round trips, `None == None` evaluation order, argument evaluation order on failure, short-circuit effects, `continue` with temporaries, more than 200 temporaries in one function, recursion, exact output, column-accurate failures on multi-call lines and return-call sites
  - [x] CLI tests: `check` does not execute, `run` and built output agree, invalid source preserves output, input overwrite via path and symlink rejected, paths with spaces, standalone output runs outside the checkout
  - [x] Examples check, build, and run; README covers CLI usage; exercised platforms recorded

## Second slice

- [x] Floats and division (§12, §13)
  - [x] Lexer: float literals with a fraction, an exponent, or both; digits on both sides of `.`; the integer leading-zero rule; literals that round to infinity rejected; `/`, `//`, `%` tokens
  - [x] Parser: `/`, `//`, `%` at the `*` level; `float` as a reserved type name; `int(...)` and `float(...)` as conversion calls
  - [x] Check: `float` type; same-type operands for arithmetic, equality, and ordering; `/` yields `float`; `//` and `%` keep the operand type; `float(int)` and `int(float)`
  - [x] Runtime: `/` on ints and floats; integer `//` and `%` with floor semantics; float `//` and `%` matching Python; `division by zero` for zero divisors, including `-0.0`; `int(float)` truncation raising `cannot convert float to int`
  - [x] Emit: unchecked IEEE `+ - *` and negation on floats; `print` selects integer or float formatting from the static type
  - [x] Float formatting matching Python `repr`: shortest round-trip digits, fixed or scientific notation by exponent, `-0.0`, `inf`, `-inf`, `nan`
  - [x] Tests: literal forms and rejections, mixed `int`/`float` errors, sign cases for `//` and `%` checked against Python, zero divisors, conversion boundaries, formatting; a float example

- [x] Optional types (§14)
  - [x] Parser: `T | None` annotations; `None | T`, other unions, and nested optionals rejected; `is None` and `is not None` at the comparison level
  - [x] Check: `T` and `None` assignable to `T | None`; a local's first assignment fixes its type and later assignments must be assignable to it
  - [x] Check: `is` only on an optional operand against literal `None`; `==` and `!=` when one operand type is assignable to the other; other operations on unnarrowed optionals rejected
  - [x] Check: narrowing facts from `is None`, `is not None`, `not`, `and`, and `or`, flowing through `if`/`elif`/`else` joins, `while` bodies, assignments, and loops as §14 describes
  - [x] Emit and runtime: `is None` and `is not None` as `nil` comparisons; printing optionals
  - [x] Tests: annotation forms and rejections, assignability, reassignment rules, narrowing after early return, in `elif`/`else`, through `and`/`or`/`not`, ended by assignment, and cleared by loop assignments

- [x] Lists, dictionaries, and `for` (§12, §15)
  - [x] Lexer: `[`, `]`, `{`, `}`, `.`; newlines inside brackets and braces produce no `NEWLINE`, `INDENT`, or `DEDENT`
  - [x] Parser: `list[T]` and `dict[K, V]` annotations; list and dict displays with trailing commas; postfix indexing and method calls; index assignment targets; `in` and `not in`; `for name in expression:`
  - [x] Bind: `len` and `range` as built-in names that file-level declarations cannot use and locals shadow; `for` names as function locals
  - [x] Check: display typing with and without an expected type; empty displays without one rejected; invariance; `int` and `str` keys only; operation types from the §15 table, including `get` on optional values; `in` on lists only for element types with `==`; `==` and `print` reject collections
  - [x] Check: `for` over lists, dictionaries, and `range`; `range` only as a `for` iterable; loop name typing; loop names not definitely assigned after the loop; `break` and `continue` in `for`
  - [x] Runtime: lists with an explicit length that store `None`; dictionaries in insertion order with stored `None` distinct from missing keys; helpers for indexing, index assignment, `append`, `pop`, `get`, `pop(k)`, and `in`, raising the §15 messages
  - [x] Lower and emit: display evaluation order; index assignment evaluating the right-hand side, the object, then the index; `for` evaluating its iterable once, rechecking list length each step, and detecting dictionary key changes; loop names keeping their last value; zero `range` step rejected
  - [x] Tests: display inference and rejections, invariance, stored `None`, out-of-range and negative indexes, missing keys, empty `pop`, dictionary order after replace and reinsert, iteration while appending and while changing keys, `range` forms, evaluation order, index expressions that do not narrow; a collections example

- [x] Records (§16)
  - [x] Parser: `class Name:` with one or more `name: Type` fields and nothing else; file scope holds `def` and `class`; field access and field assignment targets
  - [x] Bind: record names in the file-level namespace with functions and built-ins; duplicate record and field names rejected; forward and self references; constructors as call targets; locals shadowing constructors but not annotations
  - [x] Check: nominal record types; constructor arity and argument assignability; field read and write types; unknown fields rejected; `==` and `print` reject records
  - [x] Emit and runtime: records as Lua tables; constructor arguments evaluated left to right; field assignment evaluation order
  - [x] Tests: construction, mutation through aliases, recursive records with optional fields and narrowing, constructor arity and type errors, unknown fields, field expressions that do not narrow; the §16 example

- [x] Richer strings (§17)
  - [x] Lexer: triple-quoted strings with line breaks as `\n` and bare CR still rejected; `\x`, `\u`, `\U` escapes with surrogates and values above U+10FFFF rejected; f-strings with `{{`, `}}`, the field restrictions, and accurate spans inside fields
  - [x] Parser: f-string fields as expressions
  - [x] Check: printable field types; `str(...)`; string ordering; `len`, `in`, and the §17 methods; `for` over strings
  - [x] Runtime: one formatting routine shared by `print`, `str(...)`, and f-strings; code-point length and iteration; `startswith`, `endswith`, `find` by code-point index, `replace` including an empty `old`, ASCII `strip`, `split` raising `empty separator`, and `join`, matching Python
  - [x] Tests: triple-quoted line endings, numeric escape boundaries, f-string evaluation order and rejections, non-ASCII length, ordering, and method results checked against Python; a strings example

- [x] Modules (§18)
  - [x] Parser: `import name` before declarations; `module.name` in calls, constructors, and annotations
  - [x] Loader: resolve `name.wlo` in the entry file's directory; load each module once; allow cycles; report a missing module at its import; order modules by first import, depth first
  - [x] Bind: a file scope per module; import name conflicts; local shadowing of module names; `_` names private to their module; `main` required only in the entry file
  - [x] Check: collect signatures and records from every module before checking bodies
  - [x] Emit: one standalone file for all modules; per-module name mangling; source map and site entries carrying file paths
  - [x] CLI: `check`, `run`, and `build` process every reachable module; any module error prevents execution and output; the overwrite check covers every module
  - [x] Tests: multi-file program fixtures, cycles, private names, missing modules, errors reported in imported files, runtime frames across files, standalone built output; the §18 example

## Third slice

- [x] Exceptions (§19)
  - [x] Parser: `class Name(Exception):` with fields or `pass`; `raise expression` and bare `raise`; `try` with `except Class`, `except module.Class`, and `as name` clauses and `finally`; bare `except:`, class lists, `except*`, `try`/`else`, and `raise ... from` rejected
  - [x] Bind: `Exception` and the built-in exception classes as built-in names; exception classes in the file-level namespace with records; `as` names as function locals; bare `raise` only inside `except`
  - [x] Check: `message` as the first field and constructor argument; declared `message` fields and non-`Exception` bases rejected; exception classes assignable to `Exception`; `raise` operand types; clauses after `except Exception` or repeating a class rejected; `return`, `break`, and `continue` directly inside `finally` rejected
  - [x] Check: `raise` and `try` as control transfers; definite assignment and narrowing into `except` and `finally` clauses and joined after the `try`; `as` name typing
  - [x] Runtime: exception values carrying class, fields, location, and frames recorded at the raise; runtime failures raising the built-in classes; bare `raise` keeping the original location and frames; host failures left uncatchable
  - [x] Lower and emit: `try` bodies under protected calls with clause matching in order; `finally` on fall-through, `return`, `break`, `continue`, and exceptions; `return` values evaluated before `finally`; one call per line and frame mapping inside protected bodies
  - [x] Uncaught exceptions reported as `ClassName: message` with recorded frames; update existing runtime-failure expectations
  - [x] Tests: catching user and built-in exceptions, clause order, propagation through calls and modules, `finally` with each departure and with a replacing exception, bare `raise` frames, static flow rejections and joins, the §19 example

## Fourth slice

- [x] Input and output (§20)
  - [x] Bind: `main(args: list[str]) -> None` accepted as the entry signature alongside `main() -> None`; `input`, `eprint`, `read_file`, `write_file`, `exit`, and `OSError` as built-in names
  - [x] Check: built-in signatures; `eprint` accepts printable values like `print`; a statement calling `exit` transfers control like `raise`
  - [x] Runtime: a new `list[str]` of arguments passed to `main`, with invalid UTF-8 terminating before `main` runs; `input` removing `\n` and `\r\n` and returning `None` at end of input; `eprint` to stderr; whole-file `read_file` and `write_file` raising `OSError` with the host reason; `invalid UTF-8` as `ValueError`; `exit` with its status range check and without running `finally`; stdin read failures terminating like output failures
  - [x] CLI and stub: `run` passes everything after the source path verbatim; `check`, `compile`, and `build` still reject extra arguments; compiled Lua and built executables receive their own command-line arguments
  - [x] Tests: arguments through `run`, compiled, and built output, including ones that begin with `-`; `input` with LF, CRLF, a missing final newline, and empty input; file round trips, a missing file, and a caught `OSError`; invalid UTF-8; `exit` statuses, out-of-range status, unreachable statements after it, and skipped `finally`; the §20 example

## Fifth slice

- [x] Text conversions (docs/spec.md §6, §7)
  - [x] Bind: `ord` and `chr` as built-in names
  - [x] Check: `int(str)` and `float(str)` alongside the numeric conversions; `ord(str) -> int` and `chr(int) -> str`
  - [x] Runtime: `int(str)` accepting a sign and decimal digits, rejecting other text and out-of-range values with `cannot convert str to int`; `float(str)` accepting the decimal forms, `inf`, `infinity`, and `nan` in any case, rounding to nearest and overflowing to infinity, rejecting other text (including whitespace, underscores, and hexadecimal) with `cannot convert str to float`; `ord` raising `expected one character`; `chr` raising `invalid code point` for surrogates and values outside 0 through 0x10FFFF
  - [x] Tests: accepted and rejected forms for each conversion checked against Python, `int` range boundaries, float rounding and overflow, non-ASCII `ord` and `chr` round trips, surrogate and out-of-range `chr`

## Sixth slice

- [x] Unions and type aliases (docs/spec.md §3, §4, §9)
  - [x] Parser: `type Name = Type` declarations at file scope; unions of any members in any order; `module.Alias` in annotations
  - [x] Bind: aliases in the file-level namespace with functions and records; forward, self, and cross-module references; `_` aliases private; locals shadowing aliases but not annotations; `isinstance` as a built-in name
  - [x] Check: aliases equal to their expansions, including recursive ones; aliases that expand to themselves outside `list` or `dict` rejected; union flattening, member order ignored, members assignable to one another and second `list` or `dict` members rejected; assignability to and from unions; printable and `==` rules for unions; displays taking a union's list or dict member as the expected type; `isinstance` operands and class names
  - [x] Check: narrowing generalized from optionals to member sets: `is None`, `is not None`, and `isinstance` facts, joins after `if` as the union of fall-through branches, assignment of a single member, loops, and `try`
  - [x] Runtime: union values that distinguish `int` from `float` and records of different classes; `isinstance`; `==` false across member types; `print`, `str`, and f-strings formatting by the held value's type
  - [x] Tests: alias declarations and rejections, recursive JSON-shaped values built from displays, assignability and invariance, `isinstance` narrowing through `if`/`elif`/`else`, `and`, `or`, `not`, and assignment, int and float members printed and compared, records across modules; the §4 example

## Seventh slice

- [x] Standard library and JSON (docs/spec.md §12, §14)
  - [x] Loader: resolve `import name` from the entry file's directory, then from `lib/` in the installation when the entry directory has no `name.wlo`; a program's own module shadows a standard one; a module missing from both is an error at the import
  - [x] CLI: `check`, `run`, `compile`, and `build` find `lib/` from the installation, including through a symlinked launcher; compiled and built output bundle standard modules like a program's own
  - [x] `lib/json.wlo`: the `Json` alias, `JsonError`, `parse` per RFC 8259 with `int` and `float` numbers, repeated keys, surrogate pairs, unpaired surrogates rejected, and line and column in error messages; `dump` with no whitespace, dictionary order, float text from `str`, the escape rules, and `cannot encode` for NaN and infinities
  - [x] Tests: import resolution and shadowing, a missing module, standard modules in built output run outside the checkout; JSON round trips, number typing and the `int` boundary, escapes and non-ASCII text, rejected texts with their positions, non-finite floats; the §14 example

## Eighth slice

- [x] `sys` and `fs` modules (docs/spec.md §1, §11, §14)
  - [x] Loader and bind: `sys` and `fs` as compiler-provided modules, checked right after the entry file's directory without probing `lib/`, with member signatures declared in the compiler like built-ins; a program's own `sys.wlo` or `fs.wlo` shadows them
  - [x] Bind: `eprint`, `read_file`, `write_file`, and `exit` no longer built-in names; `main(args: list[str])` rejected, leaving `main() -> None` as the only entry signature
  - [x] Check: `sys.args`, `sys.eprint` accepting printable values like `print`, `sys.exit`, `fs.read_file`, and `fs.write_file`; a statement calling the standard `sys.exit` transfers control, a shadowing module's `exit` does not
  - [x] Runtime: `sys.args()` returning a new list of the arguments on each call and raising `ValueError` `invalid UTF-8` for a malformed argument; no validation before `main` runs; existing helpers reused for the moved functions
  - [x] Update `examples/number.wlo` and the existing tests to the new names
  - [x] Tests: each moved function under its module name, the old built-in names now free for user declarations, `main(args)` rejected, `sys.args()` through `run`, compiled, and built output, a malformed argument raising from `sys.args()`, `sys.exit` as a transfer, shadowing `sys` with a local module; the §14 `sys` example

## Application development milestones

Implement these ten milestones in order. Sections 15–24 of `docs/spec.md` define
accepted, unimplemented behavior. Each milestone includes focused behavior tests,
a runnable example, concise API/usage documentation, and `make test` before code
delivery. As milestones land, fold their definitions into the baseline spec,
remove obsolete amendment wording, and update implementation status.

- [x] Text and collection essentials (spec §15)
  - [x] String indexing and contiguous string/list slicing; deliberately replace
    negative-list-index rejection with the common negative-index rule
  - [x] Stable scalar sorting, Unicode 17.0 case conversion, space justification,
    and the specified f-string format subset; sorting-only named `reverse`
    arguments before general keyword calls land
  - [x] Verify boundaries, alias-preserving list copies, sorting failures before
    mutation, formatting types, and representative Unicode behavior
  - [x] Deliver a sorted, aligned log-summary or word-frequency report; measure
    sequential Unicode scanning before changing the JSON scanner

- [x] Readable function and record APIs (spec §16)
  - [x] Trailing immutable literal defaults and named arguments for functions,
    records, and the specified library signatures
  - [x] Check default types and missing, duplicate, unknown, or misplaced
    arguments; preserve written argument evaluation order
  - [x] Deliver a configurable application using a typed options record without
    positional boilerplate

- [x] Application tests and editor basics (spec §17)
  - [x] Assertions with lazy messages, useful locations, and successful-condition
    narrowing
  - [x] `willow test` discovery, checking before execution, process isolation,
    deterministic reports, `--check`, and detection of explicit exits as failures
  - [x] Basic `.wlo` syntax highlighting, four-space indentation, and editor
    check tasks for program entries/projects and test files
  - [x] Deliver passing and deliberately failing tests for a multi-module app;
    keep standalone test files alongside imported modules until project roots land

- [x] Filesystem, environment, and time (spec §18)
  - [x] Filesystem/path operations, typed metadata, environment lookup/snapshots,
    working directory, clocks, sleep, and UTC formatting
  - [x] Deliver an environment-configured directory inventory with elapsed time
    on macOS and Linux

- [x] Bytes and streaming I/O (spec §19)
  - [x] Native nominal types and built-in methods without user-defined methods or
    public FFI; common error and resource lifetime conventions
  - [x] Bytes typing, construction, sequence operations, equality, iteration, and
    strict UTF-8 conversions without implicit printing or decoding
  - [x] File and standard-stream handles, byte/text operations, close/flush, and
    deterministic cleanup through `try/finally`
  - [x] Cover shared buffering with existing `input`/`print`, EOF versus empty
    lines, invalid UTF-8, closed resources, and ordinary broken-pipe behavior
  - [x] Deliver a bounded-chunk binary copier and a JSONL filter that retains only
    the current record

- [x] Subprocess execution and control (spec §20)
  - [x] Shell-free run/capture, cwd/environment, statuses, timeout and reaping;
    drain input and both output pipes without deadlock
  - [x] Spawn with inherited/file stdio and poll/wait/terminate/kill; implement
    the specified shared-buffer and child-descriptor rules
  - [x] Deliver a command wrapper handling literal arguments, binary output,
    nonzero status, timeout, and background-helper cleanup

- [x] Friendly command-line and terminal tools (spec §21)
  - [x] Typed parser declarations/accessors, options/positionals, generated help,
    and separate usage/help/programming errors
  - [x] TTY detection, explicit color policy, styling, progress, and finish;
    preserve clean stdout when output is redirected
  - [x] Deliver a report CLI with help, typed options, terminal presentation, and
    clean piped output

- [x] HTTP and HTTPS clients (spec §22)
  - [x] Prove a maintained backend's dependency/certificate behavior for run,
    compiled Lua, and standalone build on macOS/Linux before adopting it;
    resolve any deployment-contract change explicitly
  - [x] Requests/responses, headers, query encoding, redirects, verified TLS,
    inactivity timeout, and atomic streamed downloads
  - [x] Deliver a JSON API client and binary downloader with local integration
    tests for HTTP failures, transport failures, redirects, and destination safety

- [x] TCP clients and simple services (spec §23)
  - [x] Blocking TCP connections/listeners, native methods, operation timeouts,
    EOF, partial I/O, and resource/error behavior
  - [x] Deliver a sequential line/JSON client and server sharing framing code;
    handle split UTF-8 sequences before decoding complete messages
  - [x] Exercise the pair through `willow test`, with subprocess startup, an
    ephemeral port, and deterministic child cleanup

- [x] Small projects and reusable modules (spec §24)
  - [x] Qualified imports, namespace conflicts, explicit source/dependency roots,
    module identity, and missing/ambiguous-module diagnostics
  - [x] Minimal `willow.json`, project command forms, recursive project tests,
    and preservation of explicit-file workflows
  - [x] Deliver a multi-module network/CLI application using a local dependency,
    with a documented clean-checkout-to-distributed-executable workflow

## Classes with methods

Implement methods on declared classes, including exception classes, as specified
in `docs/spec.md` §3. Classes have no inheritance beyond `Exception`, so every
method call resolves statically.

- [x] Parsing
  - [x] Method declarations after field declarations in class bodies; a first
    parameter named `self` with no annotation; reject fields after methods, a
    missing or annotated `self`, and an empty body
- [x] Binding and checking
  - [x] Per-class method tables alongside the existing native-type methods;
    unique method names that differ from field names, and no `message` method in
    exception classes
  - [x] Type `self` as its class; check method bodies and returns like functions
  - [x] Method calls with positional and keyword arguments and defaults, on
    local and module-qualified classes; require narrowing on unions; reject
    methods used as values
  - [x] Say "class" instead of "record" in diagnostics
- [x] Lowering and emission
  - [x] Emit each method as a readable Lua function and each call as a direct
    call, evaluating the receiver before the arguments
- [x] Deliver an example that uses methods on an ordinary class and an exception
  class, with focused tests and `make test`


## Language expansion milestones

Implement these milestones in order. Each task is one plan and one commit with
focused tests and `make test`. The last task of each milestone also makes the
example changes it lists. New Rosetta Code examples go in
`examples/rosettacode/` with their expected output.

- [x] Enums, enum defaults, and enum dictionary keys (spec §3–7)
  - [x] Enum declarations and values: reserve `enum`; file-level `enum` blocks
    with unique members; `E.MEMBER` and `module.E.MEMBER` as values; enums in
    annotations, unions, `==`, `isinstance`, and narrowing; `str`, `print`, and
    f-string text `E.MEMBER`; reject calls, ordering, and numeric conversion;
    a runtime representation that keeps members distinct from strings and from
    other enums in unions
  - [x] Enum members, including qualified ones, as parameter and field
    defaults; enum dictionary keys in annotations and displays, one enum type
    per key type; an `Operator` enum in `calc.wlo`, enum sort and color
    options in `report.wlo`, and Rosetta Code "Enumerations"

- [x] Tuples, tuple defaults, comparisons, and unpacking (spec §3–8)
  - [x] Tuple types and values: reserve `tuple`; `tuple[A, B]` and
    `tuple[()]` annotations; displays with `(x,)` and `()` alongside grouping;
    literal and negated-literal indexes with compile-time range errors; `len`;
    positional assignability, converting float boxing per position; one tuple
    member per union; `isinstance(v, tuple)`
  - [x] Tuple equality and ordering, left to right and stopping at the first
    unequal position; iteration with the element union, rejecting invalid
    unions; tuple defaults
  - [x] Unpacking: name and nested tuple patterns as assignment and `for`
    targets; static shape checks; repeated and starred targets rejected; one
    evaluation of the source, then left-to-right assignment under the
    local-type, definite-assignment, and narrowing rules; tuple assignment
    for the step in `fibonacci_sequence.wlo`

- [x] Keyword-only parameters and general library keyword arguments (spec §3, §5)
  - [x] Bare `*` in function and method parameter lists; keyword-only
    parameters required or defaulted in any order; positional arguments for
    them rejected; the default-ordering rule limited to positional parameters
  - [x] Keyword arguments by documented name for every standard-library
    function and every string, bytes, list, dict, and native method; the
    intrinsics stay positional-only; keyword-only `width` and `border` on
    `frame` in `banner.wlo`

- [x] Function values, bound methods, lambdas, closures, and `nonlocal` (spec §5, §9)
  - [x] Declared functions as values: file-level and qualified functions as
    values whose inferred aliases keep parameter names, defaults, and
    keyword-only requirements; calls on any callable expression, including
    callable locals that hide declarations; no equality, printing, or
    `isinstance`
  - [x] Callable types: a provided `typing` module with
    `Callable[[A, ...], R]`; compatibility with broader parameters, narrower
    returns, and extra defaulted parameters, adapting arguments, results, and
    omitted defaults at conversion; an explicit `Callable` exposes only the
    positional contract; functions with required keyword-only parameters do
    not convert; one callable member per union
  - [x] Bound methods retaining a receiver evaluated once; built-in and
    library functions as values where an expected callable type fixes the
    signature
  - [x] Nested `def` statements and closures: names bound when the definition
    runs; shared captured bindings, separate per enclosing call and reused by
    loops; self-recursion; captures definitely assigned at creation; captured
    narrowing reset at closure entry and removed after every call; Lua
    closures with traceback frame names
  - [x] `nonlocal` declarations and their rules; lambdas at lowest
    precedence, with parameter types
    from the expected callable type and inferred returns, including
    parameterless lambdas without an expected type; Rosetta Code
    "Higher-order functions" and "Closures/Value capture"

- [x] Generic functions, methods, classes, aliases, and bounded type parameters (spec §3–4)
  - [x] Generic functions with explicit specialization: type parameter lists
    on file-level and nested functions, no hiding of a parameter in scope;
    type variables limited to storing, passing, and returning; bodies checked
    for every permitted type argument; type variables in unions only
    alongside `None`, flattened on substitution; explicit `f[int](...)`;
    bodies compiled once, with no float conversion of type-variable values
  - [x] Generic call inference from arguments and the expected result: a
    unique substitution, no invented unions, and undetermined-parameter
    errors
  - [x] Generic classes and methods: `class Box[T]`, full type arguments in
    annotations, constructor inference and `Box[str](...)`, substituted fields
    and methods, method type parameters and class parameters in method
    bodies, invariance, one specialization per union, `isinstance` by class
    name, no generic exception classes, across modules
  - [x] Generic aliases, including recursion through `list` and `dict`; one
    upper bound on a class or native type, with the operations the bound
    allows;
    generic functions as values specialized by explicit arguments or an
    expected callable type; Rosetta Code "Parametric polymorphism"

- [x] Structural protocols, standard protocols, and callable type syntax (spec §2–5)
  - [x] Protocol declarations and satisfaction: reserve `protocol`;
    `protocol P:` declarations of bodiless method signatures, without
    method type parameters; generic and self-referential
    protocols; compatibility for classes, native types, and other protocols
    after substitution (broader arguments, narrower returns, matching keyword
    names, no extra required arguments); protocol assignability; no
    construction, fields, or `isinstance`
  - [x] Callable type syntax: `(A, B, ...) -> R` annotations in place of
    `typing.Callable[[A, B, ...], R]`, with the return type extending as far as
    possible and parentheses grouping a type, as in `((int) -> str) | None`;
    callable type names in diagnostics; remove the `typing` module; update the
    examples and tests that import it
  - [x] Protocol values: a protocol value is the underlying value, and each
    call dispatches on its run-time type through a generated converter per
    type and protocol that supplies implementation defaults and extra
    optional parameters and converts arguments and results; run-time tags
    for the built-in and native values that need them; only declared methods
    exposed
  - [x] Built-in standard protocols `Iterable`, `Iterator`, `ContextManager`,
    and `Generator`, reserved like `list`; protocol bounds on type parameters; a `Shape`
    protocol in `shapes.wlo`
    over `Rect` and a new `Circle` class

- [x] Extensible iteration, `iter`, `next`, and reusable range values (spec §8, §11, §14)
  - [x] `iter` and `next` built-ins and `StopIteration`; `for` over any
    `Iterable[T]`, ended only by `StopIteration` from advancement and
    leaving iterators resumable after an early exit; user-defined iterators
    and iterables
  - [x] Built-in iterables: `iter` methods on lists, dicts, strings, bytes, and
    tuples returning fresh iterators under the existing mutation rules and
    satisfying the standard protocols; `range(...)` as a reusable
    `Iterable[int]` value; `io.File.iter()`; `for` loops over files in
    place of the `readline` loops in `report.wlo` and `jsonl.wlo`

- [x] Generators and deterministic generator cleanup (spec §8, §14)
  - [x] Generator functions: `yield` statements; the three return
    annotations and yield type checks; bare `return` and no every-path rule; a
    body started on the first `next`; exhaustion, body exceptions closing the
    generator, `generator raised StopIteration`, and `generator already
    running`; generators in `for`, `iter`, and `next`; captured narrowing
    removed at suspension; each generator a coroutine, with a private cancel
    value that `__wlo_try` reports as a `"cancel"` departure, so protected
    blocks skip `except` handlers, run `finally`, and re-raise it for `close`
    to catch at the coroutine boundary
  - [x] Generator cleanup: `close()` runs pending `finally` clauses inner to
    outer without entering `except` handlers; closing unstarted, exhausted, and
    closed generators; cleanup errors; `yield` rejected directly in `finally`;
    `enter` and `exit`; `Iterator` and `Iterable` annotations hiding `close`;
    Rosetta Code
    "Generator/Exponential"

- [x] Context managers, `with`, and scoped library resources (spec §8, §14)
  - [x] `with` statements: managers satisfying `ContextManager[T]`;
    name and tuple-pattern targets; left-to-right entry and right-to-left exit,
    including after a failed entry; `exit` once with the pending exception or
    `None` on every departure; exit errors replacing the pending exception or
    transfer; definite assignment, control transfer, and no new scope
  - [x] Scoped library resources: `enter` and `exit` on `io.File`,
    `net.Connection`, and `net.Listener`, rejecting closed handles and
    standard streams on entry; generators under `with`, closing their
    suspended contexts; `with` in place of `try`/`finally` cleanup in
    `copy.wlo`, `trash.wlo`, `jobs.wlo`, and the `kv` client, server, and
    tests, with `enter` and `exit` on `framing.Channel`

- [x] Iterable sorting, tuple ordering, and `key` callbacks (spec §7)
  - [x] `sorted` over any `Iterable[T]`, consumed fully before sorting;
    sorting comparable tuples, with NaN anywhere in a key raising
    `cannot sort NaN`; `sorted` directly over dictionaries in place of the
    `keys` helpers in `report.wlo`, `listing.wlo`, and `kv/server.wlo` and
    the copy loop in `associative_array_iteration.wlo`
  - [x] Keyword-only `key` on `sorted` and `list.sort`: any element type, one
    evaluation per element in input order, `list changed during sort`, and no
    reordering after key or validation failures; a count-then-name `key` in
    `report.wlo` in place of its `by_count` grouping, and Rosetta Code "Sort
    using a custom comparator"

- [x] Strict JSON integer range handling (spec §14)
  - [x] `json.parse` raises `JsonError` `integer out of range` at the number's
    first character for integer tokens outside the `int` range
