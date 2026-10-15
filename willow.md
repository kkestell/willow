# Willow

Willow is a small, statically typed language with Python-like syntax that compiles
to readable Lua and runs on LuaJIT. Source files use the `.wlo` extension. The
command is `willow`.

This document describes the entire first slice: its language, compiler, runtime,
command-line interface, output, and acceptance criteria. It is a design to
implement, not a claim about the current repository. It deliberately replaces the
scope of the earlier, broader roadmap with something much smaller.

## 1. The first slice

The first slice should be small enough to understand from end to end. It must
compile, check, and run useful little programs, but it does not need to be a
general-purpose scripting environment yet.

It includes:

- One source file per program, with an explicit `main` function.
- Top-level functions with annotated parameters and return types.
- Inferred local variables and optional explicit local annotations.
- Integers, booleans, strings, and `None`.
- Assignment, calls, arithmetic, comparisons, conditionals, and `while` loops.
- A single output operation: `print(value)`.
- Static checking before execution, readable generated Lua, and source locations
  for compile-time and runtime errors.

It does not include collections, records, modules, exceptions, floating-point
arithmetic, file I/O, HTTP, JSON, or a package system. These are future language
features, not hidden requirements for this slice.

The compiler and runtime are initially written in plain Lua targeting bundled
LuaJIT 2.1 (with LuaJIT `ffi` permitted in the CLI for host filesystem
operations). There is no Teal dependency and no requirement to preserve the
current implementation or APIs. Reuse existing code only when it is simpler than
replacing it.

## 2. A complete program

```python
def sum_to(limit: int) -> int:
    total = 0
    current = 1
    while current <= limit:
        total = total + current
        current = current + 1
    return total

def greeting(name: str) -> str:
    return "Hello, " + name

def main() -> None:
    print(greeting("Willow"))
    print(sum_to(10))
```

Running this program prints:

```text
Hello, Willow
55
```

No imports, configuration file, implicit globals, or entry-point guard are needed.
Only function definitions are allowed at file scope. The runtime calls `main`
once after all functions have been defined.

## 3. Source syntax

Source text must be valid UTF-8. Identifiers are initially ASCII letters, digits,
and underscores, with a letter or underscore first. Identifiers are case-sensitive.

Accept both LF (`\n`) and CRLF (`\r\n`) line endings. A bare CR (`\r` not followed
by `\n`) is a lexical error anywhere in the file, including inside comments and
strings. A file that does not end with a newline implicitly terminates its final
logical line before emitting `EOF`.

Blocks use a colon followed by an indented suite. Each indentation level is four
spaces. Tabs are forbidden anywhere outside string literals and comments,
including on blank or comment-only lines. Blank lines and comment-only lines
(containing only optional spaces followed by `#` to the end of the line) do not
affect indentation tracking and do not need to align to a multiple of four spaces.
At `EOF`, any open indentation levels emit `DEDENT` tokens before the `EOF` token.

Statements normally end at a newline. Parentheses allow multiline expressions;
newlines inside them do not terminate statements or create indentation tokens.
There is no backslash continuation, semicolon separator, or one-line block syntax.

Supported statements are:

```python
value = expression
value: int = expression
function_call()
return expression
return
pass
break
continue

if condition:
    statements
elif condition:
    statements
else:
    statements

while condition:
    statements
```

`elif` and `else` are optional. Blocks must contain at least one statement; `pass`
provides an explicit empty body. Only calls may be used as expression statements.
Assignments have one name on the left and one expression on the right. There is
no chained assignment, destructuring, augmented assignment, or assignment expression.

Functions use the following form:

```python
def function_name(parameter: Type, other: Type) -> Type:
    statements
```

Parameter and return annotations are mandatory. Calls use positional arguments
with exact arity. Call targets must be bare identifiers (` IDENT '(' ... ')' `);
parenthesized call targets such as `(f)(x)` are a syntax error. Trailing commas
in parameter and argument lists are allowed. Defaults, named arguments, variadic
arguments, nested functions, and lambdas are not part of the first slice.

The reserved words are:

```text
False None True and as assert async await break case class continue def del
elif else except finally for from global if import in is lambda match nonlocal
not or pass raise return try type while with yield
```

Also reserve the built-in type names `int`, `bool`, and `str`. Only `int`, `bool`,
`str`, and `None` are valid in type annotation positions (parameters, locals, and
return types). Some reserved words have no supported construct yet. Reject those
constructs explicitly rather than interpreting them as a different language
feature.

## 4. Values and types

There are four types:

| Type | Values | Representation in generated Lua |
| --- | --- | --- |
| `int` | Bounded exact integers | Numbers with checked arithmetic (`-0.0` normalized to `0`) |
| `bool` | `True`, `False` | Booleans |
| `str` | Valid UTF-8 text | Immutable strings |
| `None` | The single value `None` | `nil` at scalar boundaries |

There is no implicit conversion between these types. In particular, `bool` is not
an integer. `None` is not assignable to `str`, `int`, or `bool`. Optional types such
as `str | None` are deferred rather than approximated with nullable types.

### Integers

The integer range is `-9007199254740991` through `9007199254740991`, inclusive
(`-(2^53 - 1)` through `2^53 - 1`). This is a deliberate departure from Python's
arbitrary-precision integers.

Integer literals use decimal digits. Except for `0`, leading zeros are rejected.
A leading minus is a unary operator, not part of the literal. Hexadecimal, binary,
underscores in literals, and floating-point literals are deferred.

Supported arithmetic is addition, subtraction, multiplication, and unary plus or
minus. Every result must remain within the integer range. Out-of-range literals
are compile-time errors; out-of-range arithmetic raises a runtime failure. There
is no wrapping or silent conversion to floating point.

Literal parsing must detect overflow without first rounding an out-of-range
decimal value into an accepted number. Arithmetic helpers must reject non-finite
or out-of-range results before exposing them as Willow integers, and must
normalize `-0.0` to `0` so negative zero is never observable.

Division, floor division, remainder, exponentiation, and bitwise operations are
excluded for now. Introducing `float` and the division rules will be a separate
design decision. Their absence must produce a clear unsupported-operation error.

### Booleans

Conditions must have type `bool`. Numbers and strings do not acquire implicit
truthiness in this slice:

```python
if count != 0:
    print(count)
```

`if count:` is a type error. This is an intentional restriction of Python-like
behavior, not an adoption of Lua truthiness. It leaves room to add a deliberate
truthiness policy later without changing any currently accepted program.

### Strings

Single- and double-quoted strings are supported. Strings cannot contain an
unescaped physical newline. Supported escapes are `\\`, `\'`, `\"`, `\n`, `\r`,
and `\t`; reject unknown escapes. Non-ASCII text can appear directly in literals.
Triple-quoted strings, raw strings, interpolation, and numeric escapes are deferred.

Strings support concatenation with `+` and equality/inequality. Equality compares
their UTF-8 contents exactly; there is no Unicode normalization.

There is no string indexing, slicing, ordering, length operation, or method API
yet. Thus the first slice does not accidentally establish byte indexing as the
meaning of Python-looking text operations. A future `bytes` type and Unicode
operations can be designed separately.

### None

`None` is an ordinary singleton value and is the return value of procedures. A
bare `return` is equivalent to `return None`. A function annotated `-> None` may
fall off its end, which also returns `None`. `None` is a valid type annotation
for parameters, local variables, and return types.

Using Lua `nil` for these scalar cases does not define the representation of future
collections. Lists and dictionaries will need an explicit way to preserve stored
`None` values independently of missing entries and length.

## 5. Expressions and evaluation

The expression forms are literals, names, parenthesized expressions, direct
function calls (`IDENT '(' ... ')'`), unary operations, binary operations, and
comparisons.

Precedence, from lowest to highest, is:

1. `or`
2. `and`
3. `not`
4. `==`, `!=`, `<`, `<=`, `>`, `>=`
5. Binary `+`, `-`
6. `*`
7. Unary `+`, `-`
8. Calls and parenthesized expressions

Binary arithmetic and boolean operators associate left to right. Grammar rules
enforce strict precedence hierarchy: operands of comparison operators (level 4)
must be arithmetic expressions (level 5 or higher), meaning `not a == b` parses
as `not (a == b)` while `a == not b` is a syntax error unless parenthesized.

`and`, `or`, and `not` accept only booleans and produce booleans. `and` and `or`
short-circuit.

Equality (`==`) and inequality (`!=`) require operands of the same type and are
defined for all four types (`int`, `bool`, `str`, and `None`). Ordering
comparisons (`<`, `<=`, `>`, `>=`) accept only integers. Identity comparisons
with `is` and `is not` are deferred.

Comparison chains such as `0 <= value < 10` are not supported initially. Reject
them at parse time rather than giving them left-associative binary semantics.
Write the corresponding boolean expression explicitly.

Evaluate operands and call arguments from left to right. Each expression is
evaluated once unless source control flow executes it again. Evaluating a later
operand or argument must not happen if an earlier operand or argument fails.
Even when comparing two `None`-typed expressions (`f() == g()`), both operands
must be evaluated left to right before producing the boolean result.

Function calls have exactly one language-level return value. Lua multiple-return
expansion is never part of Willow semantics, including when a call is the final
argument to another call.

## 6. Names, inference, and control flow

Each function has its own local scope. Parameters and all names assigned anywhere
in the function are local to that function, including assignments inside blocks.
There are no block-local declarations, module variables, or mutable globals.

Binding resolves names across the entire function before type checking and
definite-assignment analysis:

- Any name assigned anywhere in a function body binds to that function's local
  symbol throughout the entire function body, shadowing any file-level function
  or built-in name of the same identifier.
- Attempting to call a local variable (or parameter) is always a static error
  ("cannot call local variable"), even if the call appears textually before the
  local variable's first assignment; functions are not first-class values in
  this slice.
- User-defined file-level functions cannot redefine `print`. However, a local
  variable or parameter named `print` shadows the built-in `print` within that
  function (making calls to `print(...)` inside that function a "cannot call
  local variable" error).

Collect all file-level function signatures before checking bodies. Helpers may
call functions defined later in the file, and direct or mutual recursion is
allowed. Duplicate function or parameter names are errors.

Infer local types from initializers:

```python
count = 3             # int
label = "ready"       # str
finished = False      # bool
```

A variable has one stable type within its function. Reassignment must preserve
that type. An explicit local annotation (`x: Type = expr`) must include an
initializer, checks the initializer rather than converting it, and is permitted
only on the **lexically first assignment** to that variable in the function.
Annotating a parameter or placing a type annotation on any subsequent assignment
(including in an `elif`/`else` branch when the variable was already assigned in an
earlier branch) is a static error.

```python
count: int = 3
count = count + 1     # valid
count = "four"        # type error
```

For a name assigned across branches, every assignment in the function must
establish the same type. A local variable may be read at a program point only if
it is definitely assigned on all reachable control-flow paths leading to that
point:

- At the join point after an `if`/`elif`/`else` statement, a variable is
  definitely assigned if and only if the `if` statement has an `else` branch and
  every branch that falls through (i.e., does not unconditionally `return`,
  `break`, or `continue`) assigns the variable.
- If a branch unconditionally transfers control (`return`, `break`, `continue`),
  it does not constrain definite assignment for code following the `if` statement.
- If all branches of an `if`/`elif`/`else` statement unconditionally transfer
  control, the `if` statement itself transfers control, and any subsequent
  statement in the same block is diagnosed as unreachable.

```python
def choose(flag: bool) -> int:
    if flag:
        result = 1
    else:
        result = 2
    return result
```

Names first assigned only inside a `while` loop are not definitely assigned after
the loop, because the loop condition is not statically proved true and the loop
body may execute zero times. Use an initializer before the loop when the value
is needed afterward.

The checker validates both sides of branches regardless of literal conditions.
It does not prove arbitrary predicates or infer unreachable execution from a
constant condition (`if False:` or `while True:`). A non-`None` function must
return a compatible value on all paths using straightforward structural analysis;
a loop alone never establishes that a function returns. A trailing `return` is
required even after `while True:`. Statements appearing in a block after an
unconditional control transfer (`return`, `break`, `continue`, or an `if`/`else`
where all branches transfer control) are diagnosed as unreachable.

`break` and `continue` apply to the nearest enclosing `while` and are errors outside
a loop. There are no loop `else` clauses. `return` exits the current function.

## 7. Program entry and output

Every program must define exactly one function with this signature:

```python
def main() -> None:
    print("Hello, Willow")
```

The compiler rejects a missing entry point or a different `main` signature.
`main` otherwise follows normal function rules. The runtime invokes it once at
startup; user-written calls to it are ordinary calls.

The only built-in operation is `print(value)`. It takes exactly one scalar value
of any of the four supported types, writes its text followed by a newline (`\n`),
and returns `None`. The compiler recognizes this finite set of accepted argument
types; it does not introduce a public `any` type or user-defined overloads.

- Strings are printed as their contents, without quotation marks.
- Integers are printed in decimal without a fractional part, exponent, or negative zero (`0` prints as `0`).
- Booleans print as `True` and `False`.
- `None` prints as `None`.

Output uses stdout and UTF-8 for text. An observed write or flush failure
terminates the program with a runtime diagnostic. Successful writes do not
promise durable storage. There is no input, argument access, process-control API,
or other standard library in this slice. There is no implicit access to Lua
globals or `require`.

## 8. Command-line interface and artifacts

The interface is file-oriented:

```sh
willow check hello.wlo
willow run hello.wlo
willow build hello.wlo -o hello.lua
luajit hello.lua
```

`check` parses, resolves names, and checks types without running the program or
writing generated files. `run` performs the same checks, generates Lua in memory,
and executes it on the bundled LuaJIT. `build` performs the same checks and writes
one standalone Lua file. The `-o <path>` output option is required for `build`;
there is no project-directory discovery or implicit output directory in this slice.

Reject extra arguments and unknown options. Program arguments and compiler
configuration files can be added later with explicit syntax.

Success returns exit status 0. Source errors, invalid CLI usage, build failures,
and runtime failures return a nonzero status; use 1 initially. Diagnostics go to
stderr. Program output goes to stdout. Check the complete source before executing
any user code or replacing a build output.

Build output contains the small runtime helpers it needs, translated functions,
source-location metadata, and entry-point invocation. It requires LuaJIT 2.1 but
does not require Willow, the source file, a source checkout, or additional Lua
packages at execution time. Generate Lua source, not LuaJIT bytecode.

For a failed build, preserve any existing output file. For a successful build,
write to a temporary sibling file in the target directory and atomically replace
the target after the write and flush succeed. Reject an output path that would
overwrite the input source file, including aliases (such as symlinks, hardlinks,
or relative paths) identified via host OS file identity checks (using LuaJIT
`ffi` for `stat` on POSIX / file handle information on Windows).

Keep the generated file readable and deterministic for identical source and
recorded source path. Use stable helper names, ordinary Lua functions, and explicit
temporaries. Do not add timestamps or random identifiers. Readability is for
inspection; generated Lua layout and helper names are not a public API.

## 9. Compiler architecture

Use a small sequence of explicit passes:

```text
UTF-8 source
    -> tokens with source spans
    -> syntax tree
    -> resolved names and function signatures
    -> checked types and definite assignment
    -> lowered operations and control flow
    -> Lua text and source-location map
```

The syntax tree describes Willow, not Lua. Keep source spans on nodes throughout
the pipeline. Binding assigns stable symbol identities; later passes do not
resolve variables by concatenating source names into generated code.

The checker assigns concrete types to expressions and rejects unsupported uses.
It has no fallback to `any`, no whole-program inference engine, and no implicit
conversion pass. Record resolved function targets and operation types for emission.

Lowering is a small compiler pass, not an optimizer or an elaborate intermediate
language. Its job is to make source semantics explicit: evaluation order,
short-circuit branches, checked integer operations, loop transfers, single return
values, and built-in calls. Add structured lowered nodes only where they clarify
these requirements.

The emitter consumes checked/lowered nodes and obeys these LuaJIT invariants:

- **No semantic guessing:** Willow `+` becomes checked integer addition or string
  concatenation strictly according to the types established by the checker.
- **Mutual recursion:** Forward-declare all user Lua function locals at file top
  before assigning their function bodies so mutually recursive functions refer to
  the intended bindings.
- **Hygiene:** Give internal helpers and temporaries reserved prefixes (e.g.,
  `__wlo_`) that cannot collide with mangled user symbols or Lua keywords.
- **Preserved stack frames (no tail-call erasure):** Lower `return <call_expr>` to
  assign to a temporary before returning (`local _r = f(); return _r`) so LuaJIT
  never emits `BC_CALLT`, preserving exact caller stack frames for runtime
  tracebacks.
- **One call per generated Lua line:** Emit at most one user function call or
  fallible runtime helper call per generated Lua line so that Lua line numbers in
  `debug.getinfo` map unambiguously to a single Willow `(line, column)` call site.
- **Scoped temporaries and `continue` safety:** Wrap lowered statement temporaries
  in `do ... end` blocks (or recycle temporary registers after statement exit) so
  functions never exceed LuaJIT's 200-local-variable limit (`LJ_MAX_LOCVAR`).
  Inside `while` loops, wrap the loop body in an inner `do ... end` block placed
  *before* the `::__wlo_cont_N::` label so `goto __wlo_cont_N` never jumps into
  the scope of a local temporary.
- **String escaping:** Escape generated string literals with a dedicated routine
  and verify non-ASCII and escaped text round trips exactly.

There is no optimization requirement beyond avoiding obviously unnecessary
machinery. In particular, do not add constant folding that changes overflow or
failure timing while establishing the basic semantics.

### Suggested repository layout

```text
willow                 launcher
compiler/
    cli.lua
    lexer.lua
    parser.lua
    bind.lua
    check.lua
    lower.lua
    emit.lua
runtime/
    core.lua
tests/
    unit/
    programs/
examples/
    hello.wlo
    sums.wlo
vendor/
    luajit/
```

These are responsibility boundaries, not a mandate for a framework or an exact
file count. Shared source spans, diagnostics, and AST definitions may have small
support modules. Keep parsing, checking, and emission separately testable.

The launcher finds its installation and invokes the compiler using bundled
LuaJIT. Development setup needs a documented way to build that pinned runtime and
run tests. Compiler operation must not download dependencies or contact a service.

## 10. Runtime and diagnostics

The runtime is deliberately small: checked integer operations, scalar printing,
source-error construction, and top-level failure handling. User functions and
ordinary control flow compile to Lua; do not implement a Willow interpreter.

Compile-time diagnostics use this shape:

```text
hello.wlo:8:5: error: expected int, received str
```

Positions are one-based; columns count UTF-8 code points, and internal spans retain
byte offsets for slicing source. Tokenization maintains the correspondence.
Prefer one precise error to a cascade. A lexer/parser may stop at the first
error; the checker may collect independent errors when it can do so reliably.

Runtime errors should identify the failing source operation and Willow callers:

```text
hello.wlo:4:12: error: integer overflow
  in multiply at hello.wlo:4:12
  called from main at hello.wlo:8:5
```

Pass source locations (or compact site IDs) explicitly to runtime helpers that
can fail, and map generated Lua line numbers back to Willow `(line, column,
function_name)` entries for traceback frames. Because emission guarantees at most
one call per Lua line and disables tail-call frame erasure, each active Lua frame
in `debug.getinfo` maps deterministically to its Willow call site.

Preserve the original failure location while adding caller information. Hide
routine runtime and entry-wrapper frames in normal diagnostics. An optional
developer trace mode may expose generated Lua locations, but is not required for
the first slice.

There is no user-visible exception hierarchy or catch syntax yet. All runtime
failures terminate execution. Internally, represent errors as a structured table
containing at least `category`, `message`, and `location` so future exception
handling does not require parsing display text. In the top-level `xpcall` error
handler, if LuaJIT raises a raw VM string error (such as `"stack overflow"` or
`"not enough memory"`) rather than a structured Willow error table, wrap it into a
structured runtime error and attach the innermost surviving Willow frame location
from the traceback.

Unexpected compiler failures must be reported as internal compiler errors, not
disguised as user type errors. Runtime stack exhaustion and host I/O failures can
have host-dependent details; report the available source context without claiming
recovery or identical messages across platforms.

## 11. Testing and completion

Tests should establish language behavior, not just mirror compiler internals.

Cover these layers:

- Lexer/parser cases: indentation, tabs anywhere outside strings/comments, blank
  and comment-only lines with arbitrary space indentation, bare CR rejection,
  missing final newline, UTF-8, escapes, precedence (`not a == b` vs `a == not b`),
  chained comparison rejection, parenthesized call target rejection, multiline
  calls, malformed blocks, and clear rejection of unsupported syntax.
- Static cases: inferred locals, explicit annotations (and rejection on non-first
  assignments), whole-function shadowing (including calling a local that shadows
  a function or `print` before its assignment), forward calls, mutual recursion,
  wrong arity, wrong operands, missing returns (including after `while True`),
  definite assignment across terminating and non-terminating branches,
  unreachable code after terminating `if`/`else`, incompatible branch
  assignments, and misuse of loop transfers.
- Runtime cases: integer boundaries (`-(2^53 - 1)` and `2^53 - 1`), overflow on
  `+`, `-`, `*`, `-0.0` normalization to `0`, string round trips, `None == None`
  evaluation order, left-to-right argument evaluation when an early argument
  fails, short-circuit effects, `continue` inside loops with local temporaries,
  deeply nested expressions (>200 temporaries in a function), recursion, exact
  output, and column-accurate source-mapped failures across multi-call lines and
  return-call sites.
- CLI/artifact cases: `check` does not execute, `run` and built output agree,
  invalid source does not replace output, overwriting input via path or symlink
  is rejected, paths with spaces work, and standalone output runs without the
  source checkout or installed compiler.

Use small source programs with expected stdout, exit status, or diagnostics.
Where the supported behavior agrees with Python, Python can provide an additional
comparison. Willow's bounded integers, strict conditions, and restricted type rules
need their own explicit expectations.

The first slice is complete when:

1. The complete example in this document checks, builds, and runs.
2. Every accepted construct has positive and relevant negative tests.
3. Type errors prevent all user execution.
4. Integer overflow and `-0.0` cannot silently produce an invalid or `-0` Willow value.
5. Runtime failures report accurate original source lines, columns, and caller frames.
6. Generated output runs independently on the supported LuaJIT runtime.
7. Active tooling and examples use Willow and `.wlo`, with no Teal dependency.
8. Setup and test commands work on the initially supported host platforms, with
   the exercised platforms recorded rather than assumed.

Performance work comes after correctness. There is no benchmark target or optimizer
deliverable for this slice.

## 12. Growth without premature machinery

Preserve these boundaries now:

- Willow types and operations remain distinct from their Lua representation.
- Function signatures are collected independently from checking bodies.
- Runtime calls have explicit typed compiler definitions.
- AST and lowered nodes retain source locations.
- Scalar `None` representation does not dictate future collection storage.
- Unsupported syntax is rejected rather than assigned provisional semantics.
- Emitted runtime helpers are private implementation details.

These choices allow later work without implementing it early. Likely additions
are optional types, floating-point numbers and division, lists and dictionaries,
simple records, modules, richer strings, exceptions, and a small I/O library.
Each should arrive with its own semantics and examples.

Do not reserve architecture for a package manager, plugin system, optimizer,
self-hosted compiler, full Python object model, or language server. Ordinary
modules and clear pass interfaces are enough preparation.

The first slice makes no promise of Python source compatibility, Python package
compatibility, or access to arbitrary Lua libraries. Its promise is narrower:
small programs that read naturally, are statically checked, and compile to
understandable Lua with predictable behavior.
