# Bootstrap design: a self-hosting native Willow

Status: design agreed 2026-10-23, not yet started. This document records the
plan for reimplementing Willow as a multi-stage, self-hosting compiler that
emits QBE intermediate language and links against libgc. It replaces the
Lua/LuaJIT implementation in `compiler/` and `runtime/` once the native
compiler passes the existing test programs. `docs/spec.md` remains the
language specification; the spec changes this plan requires are listed in
§9.

## 1. Goals and non-goals

Goals:

- A compiler for the full language in `docs/spec.md`, written in Willow, that
  compiles itself.
- Native executables for macOS and Linux on arm64 and amd64 through QBE.
- As little non-Willow code as possible. The runtime is written in Willow.
  The only permanent foreign code is a small Rust translator for the first
  stage, a few dozen lines of assembly for stack switching, and libc, libgc,
  and the system assembler and linker.
- A bootstrap chain that is rebuilt from source in one command, with no
  checked-in binaries or generated code.

Non-goals:

- Performance work beyond what QBE gives for free. Measure first.
- Debug information, cross-compilation, or targets QBE does not support.
- Keeping the Lua backend alive after the native compiler is conformant.

## 2. Stages

The chain has three compilers. Each is named by the language it accepts and
the language it is written in.

| Stage | Written in | Accepts | Role |
| --- | --- | --- | --- |
| 0 | Rust | L0 | Translator from L0 to QBE IL. No runtime of its own. |
| 1 | L0 | Full Willow | Bootstrap compiler. Compiled by stage 0, then by itself. |
| 2 | Full Willow | Full Willow | The compiler users run. Compiled by stage 1, then by itself. |

L0 is the subset in §3. It is defined as whatever stage 0 accepts, and it is
frozen once stage 1 is complete.

Why not a stage written in L0 that accepts only L0: a compiler for the full
language written in L0 can compile itself too, because L0 is a subset of the
full language. The fixpoint test in §8 works on stage 1 directly. A separate
same-subset stage would prove nothing extra and would be throwaway code.

Why stage 2 exists: writing the long-lived compiler in L0 forever is
unpleasant. Once stage 1 works, the compiler is rewritten in full Willow and
stage 1 freezes. Stage 1 then only has to accept the subset of the language
that stage 2's source actually uses. Stage 2 keeps its own source
conservative so stage 1 never needs to change again.

Escape hatch: stage 0 is small Rust, so extending L0 during stage 1
development is cheap when a missing feature turns out to hurt. Candidates are
keyword arguments and defaults, and tuples. Exceptions, closures, generators,
and async never enter L0; the whole point of stage 1 is to build them.

Build order:

```text
cargo build  -> willow0                     (stage 0)
willow0  bootstrap/stage1/*.wlo + core -> willow1a
willow1a bootstrap/stage1/*.wlo + core -> willow1b
willow1b bootstrap/stage1/*.wlo + core -> willow1c   ; willow1b.ssa == willow1c.ssa
willow1b compiler/*.wlo + core + lib     -> willow2a
willow2a compiler/*.wlo + core + lib     -> willow2b ; willow2a.ssa == willow2b.ssa
```

## 3. L0, the stage 0 language

The design rule for L0: rich enough that a type checker with unions and
generics is pleasant to write in it, and poor enough that stage 0 needs no
runtime support beyond the intrinsics in §5. Sum types with narrowing are the
feature that decides whether a compiler is pleasant to write, so unions are in.

Everything in L0 has exactly the semantics `docs/spec.md` gives it. L0 adds
nothing to the language except the intrinsic layer in §5, which only the
`core` module may use.

Included:

- Types: `int`, `float`, `bool`, `str`, `None`, `list[T]`, `dict[K, V]` with
  `int`, `str`, or enum keys, classes with fields and methods and no
  inheritance, enums, unions, type aliases, module-qualified names.
- Narrowing: `is None`, `is not None`, `isinstance` on classes and scalars,
  with the `and`, `or`, and `not` fact rules, `if`/`elif`/`else` and `while`
  flow, assignment narrowing, and the `assert` rule. Definite assignment and
  control-transfer checking as specified.
- Declarations: `def` with annotated positional parameters and no defaults or
  keyword-only parameters, `class` with fields and methods and field defaults
  limited to literals, `enum`, `type`, `import`.
- Statements: assignment to names, indexes, and fields, annotated first
  assignment, expression statements, `if`, `while`, `for` over lists, dicts,
  strings, and `range`, `break`, `continue`, `return`, `pass`, `assert`.
- Expressions: literals, f-strings without format specifications, arithmetic
  including checked integer overflow and floor division, comparisons, `and`,
  `or`, `not`, `in` and `not in`, calls, method calls, indexing, slicing,
  field access, constructors with positional arguments, enum members.
- Built-ins: `print`, `len`, `str`, `int`, `float`, `range`, `ord`, `chr`,
  `isinstance`; list `append`, `pop`, `extend`, `reverse`; dict `get` with and
  without a default, `pop`, `keys`, `values`, `items` as `for` sources only;
  string `find`, `split`, `join`, `startswith`, `endswith`, `strip`,
  `replace`, `removeprefix`, `removesuffix`, `isdigit`, `isalpha`, `isalnum`,
  `isspace`, `ljust`, `rjust`.
- Host: `sys.args`, `sys.exit`, `sys.eprint`, and reading and writing a whole
  file as a string. These are the parts of `sys` and `fs` the compiler needs,
  with the signatures the spec gives them.

Excluded, and delivered by stage 1: exceptions, `try`, `raise`, `with`,
generators and `yield`, `async` and `await`, closures, nested `def`, lambdas,
callable types and function values, tuples, protocols, user-declared type
parameters, defaults other than literals, keyword arguments, `bytes`, `input`,
format specifications, `sorted` and `sort`, and all other built-ins and
standard library modules.

Runtime failures in L0 are fatal. `IndexError`, `KeyError`,
`ZeroDivisionError`, `OverflowError`, `ValueError`, and `AssertionError` print
`error: <Class>: <message>` to stderr and exit with status 1, using the spec's
messages. Stage 0 does not record locations or frames for them. This is a
temporary deviation from spec §13 that stage 1 removes.

## 4. Value representation

Every Willow value occupies one 8-byte slot. The static type decides what the
slot holds.

| Static type | Slot contents |
| --- | --- |
| `int` | i64 |
| `float` | f64 bits |
| `bool` | 0 or 1 |
| enum | member ordinal |
| `None` | 0 |
| `str`, `list`, `dict`, class, boxed scalar | pointer to a heap or data object, or 0 for `None` |
| union | pointer or 0; scalars are boxed on entry |

Integers are the symmetric range `-(2^63 - 1)` through `2^63 - 1`. The value
`-2^63` is treated as overflow so the spec's guarantees hold: `abs` cannot
overflow and there is no asymmetric minimum. This widens the current `int`
range (§9).

Heap objects start with one header word that points to a type descriptor. The
compiler emits one descriptor per class, enum, and boxed scalar kind as a
`data` symbol holding the type's name. `isinstance` on a union compares the
header word against the descriptor symbol. Narrowing from a union to a scalar
type unboxes; widening from a scalar type to a union boxes. The compiler
inserts these conversions at every assignability point: assignment, argument,
return, display element, field store, and collection store.

Strings are immutable UTF-8: header, byte length, bytes, and a trailing zero
so they can be passed to libc. String literals are `data` objects with the
same layout, so a literal and a heap string are indistinguishable. Code-point
indexing walks the bytes, as spec §7 allows.

Lists are header, length, capacity, and a pointer to a slot array. Dicts keep
insertion order with an entries array of key, value, and liveness, plus a hash
index. Keys hash by kind; the compiler passes the key kind when it creates a
dict, so one dict implementation serves `int`, `str`, and enum keys.

Collections store raw slots and never inspect them. A float stored in a list
is converted with QBE `cast` to an integer register at the call site and back
when loaded; this was verified to work. Built-in generics therefore cost
nothing at run time and need no monomorphization.

User-declared generics in stage 1 are monomorphized per instantiation. The
whole program is compiled at once, so this is a table of instantiations in
the emitter, and it avoids the problem that a generic body writing a `T` into
`T | None` cannot know whether to box.

Equality on unions and `in` on collections call a core function that compares
descriptors and then contents. Strings compare by bytes.

## 5. The core module and intrinsics

`core` is a Willow module compiled into every program. Every built-in
operation lowers either to inline QBE or to a call into `core`. Stage 0
contains no runtime code; it knows the names of core functions and the
inline sequences for arithmetic and comparisons.

Only `core` may use the intrinsic layer. The checker rejects it elsewhere by
module name. The layer is:

- A type `ptr`, a raw address. `None` is not assignable to it; use `0` tests
  through `__addr_is_null`.
- A type `word`, an uninspected 8-byte slot. Core uses it for collection
  elements and boxing payloads.
- `__alloc(size: int) -> ptr` and `__alloc_atomic(size: int) -> ptr`, which
  call `GC_malloc` and `GC_malloc_atomic`. Strings and slot arrays that hold
  no pointers use the atomic form.
- `__load1`, `__store1`, `__load4`, `__store4`, `__load8`, `__store8`, taking
  a `ptr` and a byte offset.
- Reinterpretations between `word` and each of `int`, `float`, `bool`, `ptr`,
  and every reference type, in both directions. They emit QBE `copy` or
  `cast` and nothing else.
- `extern def name(params) -> R` declares a C function. Parameter and return
  types are limited to `int` and `ptr` as QBE `l`, `float` as `d`, and `cint`
  as QBE `w` for C `int`. A trailing `...` marks a variadic function; calls
  then pass extra arguments with their own types and the emitter writes the
  QBE `...` marker. This is how `core` reaches `write`, `read`, `open`,
  `close`, `exit`, `memcpy`, `memcmp`, `strtod`, `snprintf`, `GC_init`, and
  the GC allocation functions.

Core's own failures call `core.fail(class_name, message)`, which writes the
report and exits in L0 and sets the pending exception in stage 1 (§6).

What stays outside Willow for the life of the project:

- The coroutine context switch, about thirty lines of assembly per target
  (§6). The compiler holds these as strings and appends the right one to the
  assembly QBE produces, so there is no separate assembly file in the build.
- Program entry. The emitter writes an exported `main` that calls `GC_init`,
  hands `argc` and `argv` to `core`, calls the program's `main`, flushes
  stdout, and returns 0.

## 6. Stage 1 runtime decisions

These are not L0 features, but the representation in §4 and the core API have
to leave room for them, so they are decided now.

Exceptions use a pending-exception flag, not setjmp/longjmp. Every function
returns normally. `raise` and `core.fail` store the exception in a global and
return a dummy value. After each call that can raise, the emitter loads the
global and branches to the innermost handler block, or to the function's exit
path when there is none. `finally` is a handler block that runs its body and
then re-tests the flag. The cost is one load and one branch per call on the
path that does not raise. Nothing unwinds across foreign frames, so `core` is
free to call back into user code for sort keys, iterator protocols, and
context cleanup.

Tracebacks fall out of the same mechanism. When a function observes the flag
set after a call, it appends a frame to the exception: `in f at <call site>`
if the exception has no frames yet, otherwise `called from f at <call site>`.
A `raise` statement appends its own `in f at <location>` frame. Functions in
`core` are compiled with frame recording off, so a failing list index reports
the location of the index expression, as spec §13 requires.

Generators and async tasks are stackful coroutines. Stacks are allocated from
the GC heap, so a suspended stack is scanned as an ordinary heap object. On
every switch, core calls `GC_set_stackbottom` with the base of the stack
being resumed so the collector scans the running stack correctly. The context
switch saves and restores callee-saved registers and the stack pointer. A
state-machine lowering was considered and rejected: it is a large compiler
pass, and it would need a second mechanism for async.

Stack overflow and out-of-memory remain fatal as spec §10 says. Detecting
overflow on coroutine stacks with a guard page is deferred until it is a
demonstrated problem.

The async event loop is written in Willow over `poll` or `kqueue` through
`extern`. The existing design in `runtime/aio.lua` carries over.

Float formatting is Python `repr`: try `%.15g`, `%.16g`, and `%.17g` through
`snprintf` and take the shortest that round-trips through `strtod`. Unicode
case mapping tables are generated once from Unicode 17.0 as Willow data.

## 7. Stage 0 in Rust

Stage 0 is a single crate, `willow0`. It has a lexer, a parser, a binder and
checker for L0, a QBE emitter, and a driver. It does whole-program compilation:
it loads the entry file, follows imports, always adds `core`, checks
everything, and writes one `.ssa` file. The driver then runs `qbe` and `cc`
and links libgc. Diagnostics use the spec §13 format.

Symbols are `$W.<module>.<name>` with dots in module names kept as dots; QBE
accepts them, verified. Class descriptors are `$W.<module>.<Class>.type`.
String literals are `$W.str.<n>`.

Stage 0 does no optimization. QBE's own passes are enough.

Estimated size is four to six thousand lines. It never grows beyond L0 except
through the escape hatch in §2.

## 8. Testing

- `bootstrap/tests/programs/` holds L0 programs with expected stdout, exit
  status, and stderr, in the same `.wlo`/`.out`/`.err` layout as
  `tests/programs/`. They exercise L0 and `core` under stage 0 before anything
  is built on them. `sum_to.wlo` is there now and is milestone 1's done
  condition.
- `core` has its own tests in L0, using `assert`, run under stage 0. Because a
  failure in core could be in core or in the compiler that compiled it, and
  the Lua implementation has no intrinsics to adjudicate, core stays boring:
  no cleverness that makes it hard to read a failing test.
- `tests/programs/` is the conformance suite for stage 1 and stage 2. The
  Lua implementation stays in the repository as the oracle until the native
  compiler passes all of them.
- Fixpoint: a compiler compiled by itself must emit byte-identical `.ssa` for
  its own source. Emission is therefore deterministic: no hash-ordered
  iteration anywhere in the compiler, which Willow's insertion-ordered dicts
  already guarantee.
- `bootstrap/tests/run.sh` drives the L0 programs: it builds each with
  `willow0`, runs it from its own directory, and compares stdout, stderr, and
  exit status with the same conventions as `tests/run.lua`. `make bootstrap`
  builds stage 0 and `make bootstrap-test` runs the programs. The runner moves
  to a Willow program once stage 2 exists.

## 9. Specification changes

Made on 2026-10-23, ahead of the implementation:

- §4: `int` becomes the symmetric 64-bit range.
- §1: remove "Programs cannot access Lua globals or `require`".
- §12: `willow compile -o <output>` writes QBE intermediate language, and
  `willow build -o <output>` writes a native executable. Remove the LuaJIT
  bundling description. `willow run` builds to a temporary file and runs it.
- Intro: the language compiles to native code through QBE.

Everything else, including diagnostics format, string semantics, dict
ordering, exception messages, and the async model, is unchanged. The L0
runtime-failure format in §3 is an implementation gap, not a spec change.

## 10. Toolchain and layout

Verified on this machine on 2026-10-23: QBE 1.3 with `arm64_apple` as the
default target, bdw-gc 8.2.12 at `/opt/homebrew/opt/bdw-gc`, Rust 1.96, and
Apple `cc`. A program using dotted QBE symbols, `cast`, a variadic `printf`
call, `GC_init`, and `GC_malloc` was assembled, linked, and run.

Dependencies for compiling programs: `qbe`, `cc`, libgc. Dependency for
rebuilding the bootstrap: `cargo`. Linux uses `amd64_sysv` or `arm64` and the
distribution's libgc. `bootstrap/Dockerfile` extends the gnat agent image with
QBE 1.3 built from the release tarball, `libgc-dev`, `pkg-config`, and a Rust
toolchain; the agents that do this work run in it, on arm64 Debian. Each
change is therefore tested on Linux arm64 by its agent and on macOS arm64 by
the operator before it merges. `amd64_sysv` has no test machine yet.

```text
bootstrap/
  Dockerfile   agent image with the native toolchain
  stage0/      Rust crate willow0
  core/        core module in L0
  stage1/      stage 1 compiler in L0
  tests/       run.sh and programs/ with L0 programs and core tests
compiler/      stage 2 in full Willow (replaces the Lua compiler when ready)
lib/           standard library in Willow (replaces runtime/*.lua)
```

### Portability

Every change must build and pass on both Linux and macOS. The rules that keep
that from being rediscovered per task:

- The driver picks the QBE target from the host: `arm64_apple` or
  `amd64_apple` on Darwin, `arm64` or `amd64_sysv` on Linux. It finds libgc
  with `pkg-config --cflags --libs bdw-gc` and falls back to `-lgc`.
- QBE handles symbol prefixing, so core never spells a C symbol differently
  per platform.
- The compiler exposes the target operating system to `core` as the intrinsic
  constant `__os`, which is `"linux"` or `"darwin"` and is folded at compile
  time. Core keeps one table of libc constants per operating system: `open`
  flags, `errno` values, and the layouts of `pollfd`, `stat`, and `dirent`.
  `errno` itself is read through `__errno_location` on Linux and `__error` on
  Darwin, behind one core function.
- The event loop uses `poll`, which both platforms provide, not `kqueue` or
  `epoll`.
- Integer-typed `extern` parameters that are C `int`, `mode_t`, or `socklen_t`
  are declared `cint`. `size_t`, `ssize_t`, `off_t`, and pointers are `int`
  or `ptr`.

The Lua `compiler/` and `runtime/` stay in place until stage 2 passes
`tests/programs/`, then are deleted along with the LuaJIT vendor tree.

## 11. Milestones

1. A vertical slice: stage 0 compiles functions over `int`, `bool`, and `str`
   literals and concatenation with `if`, `while`, and `print`, through the
   intrinsic layer and a first `core` that provides string objects, `+` on
   strings, and `print` over `extern write`. `sum_to` from spec §1 runs
   natively, which is `bootstrap/tests/programs/sum_to.wlo`.
2. Intrinsics and the first `core`: strings, lists, dicts, boxing and unions,
   f-strings, slicing, conversions, file I/O, `sys`. All of §3. L0 test suite
   and core tests pass.
3. Stage 1 front end in L0: lexer, parser, and binder for the full language.
   It parses and binds every file in `tests/` and `examples/`.
4. Stage 1 checker and emitter, with `core` grown to the full runtime in the
   order exceptions, closures, tuples, protocols and generics, generators,
   async. Each slice passes its `tests/programs/` cases.
5. Fixpoint: stage 1 compiles itself identically.
6. Stage 2 in full Willow, standard library ported to `lib/`, test runner in
   Willow, Lua implementation deleted.

## 12. Open questions

- Local native builds have set off the virus checker before. Every test run
  in this plan builds native binaries.
