# Willow

Willow is a small, statically typed language with Python-like syntax that compiles
to readable Lua and runs on LuaJIT. Source files use the `.wlo` extension. The
command is `willow`.

This document describes the first slice (§1–§11), the second slice that extends
it (§12–§18), and the third slice (§19): their language, compiler, runtime,
command-line interface, output, and acceptance criteria. It is a design to implement, not a claim about
the current repository. It deliberately replaces the scope of the earlier, broader
roadmap with something much smaller.

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
arithmetic, file I/O, HTTP, JSON, or a package system. The second slice (§12) adds
floats, optional types, collections, records, richer strings, and modules, and the
third slice (§19) adds exceptions. The rest are future language features, not
hidden requirements for any slice.

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
as `str | None` arrive in §14.

### Integers

The integer range is `-9007199254740991` through `9007199254740991`, inclusive
(`-(2^53 - 1)` through `2^53 - 1`). This is a deliberate departure from Python's
arbitrary-precision integers.

Integer literals use decimal digits. Except for `0`, leading zeros are rejected.
A leading minus is a unary operator, not part of the literal. Hexadecimal, binary,
and underscores in literals are deferred. §13 adds floating-point literals.

Supported arithmetic is addition, subtraction, multiplication, and unary plus or
minus. Every result must remain within the integer range. Out-of-range literals
are compile-time errors; out-of-range arithmetic raises a runtime failure. There
is no wrapping or silent conversion to floating point.

Literal parsing must detect overflow without first rounding an out-of-range
decimal value into an accepted number. Arithmetic helpers must reject non-finite
or out-of-range results before exposing them as Willow integers, and must
normalize `-0.0` to `0` so negative zero is never observable.

Division, floor division, and remainder arrive with `float` in §13. Exponentiation
and bitwise operations are excluded, as is division before §13. Their absence must
produce a clear unsupported-operation error.

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
§17 adds triple-quoted strings, numeric escapes, and interpolation. Raw strings are
deferred.

Strings support concatenation with `+` and equality/inequality. Equality compares
their UTF-8 contents exactly; there is no Unicode normalization.

The first slice has no string indexing, slicing, ordering, length operation, or
method API, so it does not accidentally establish byte indexing as the meaning of
Python-looking text operations. §17 adds length, ordering, iteration, and methods
defined on code points.

### None

`None` is an ordinary singleton value and is the return value of procedures. A
bare `return` is equivalent to `return None`. A function annotated `-> None` may
fall off its end, which also returns `None`. `None` is a valid type annotation
for parameters, local variables, and return types.

Using Lua `nil` for these scalar cases does not define collection storage (§15).

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
comparisons (`<`, `<=`, `>`, `>=`) accept only integers. §14 adds `is None` and
`is not None`.

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

In the first slice, all runtime failures terminate execution. §19 makes them
exceptions that programs can catch. Internally, represent errors as a structured table
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

## 12. The second slice

The second slice adds six features to the first, in this order:

1. Floats and division (§13)
2. Optional types (§14)
3. Lists, dictionaries, and `for` loops (§15)
4. Records (§16)
5. Richer strings (§17)
6. Modules (§18)

Each feature builds on the ones before it. The rules of §1–§11 hold unless a later
section changes them.

### Syntax

File scope holds `import` statements (§18) followed by `def` and `class` (§16)
declarations in any order.

Statements add `for` loops and assignment to index and field targets:

```python
for name in expression:
    statements

items[index] = expression
point.x = expression
```

An assignment target is a name, an index expression, or a field expression. Only a
name target may carry an annotation. `break` and `continue` apply to the nearest
enclosing `while` or `for`.

Precedence, from lowest to highest, becomes:

1. `or`
2. `and`
3. `not`
4. `==`, `!=`, `<`, `<=`, `>`, `>=`, `is`, `is not`, `in`, `not in`
5. Binary `+`, `-`
6. `*`, `/`, `//`, `%`
7. Unary `+`, `-`
8. Postfix: calls, indexing `a[i]`, and field or method access `a.name`
9. Literals, names, parenthesized expressions, and list and dict displays

Level 4 keeps the first-slice rules: operands come from level 5 or higher, and
chains are rejected. Postfix operations chain left to right, as in
`rows[0].name` and `text.strip().split(",")`.

A call has one of three forms: a function, built-in, conversion (`int`, `float`,
`str`), or record constructor by bare name (`area(p)`), a module member (`geometry.area(p)`), or a built-in method on a value
(`items.append(x)`). Functions and methods are not values, so `(f)(x)`,
`items[0](x)`, and an uncalled method such as `items.append` are errors.

Newlines inside brackets and braces, as inside parentheses, do not end statements
or create indentation tokens. List and dict displays allow trailing commas.

Annotation types are:

```text
int  float  bool  str  None
list[T]  dict[K, V]
Record  module.Record
T | None
```

`float`, `list`, and `dict` join the reserved type names. `len` and `range` join
`print` as built-in names: file-level declarations cannot use them, and a local of
the same name shadows them as described in §6.

### Values and evaluation

The scalar types are `int`, `float`, `bool`, `str`, and `None`. Equality, `print`,
`str(...)`, and f-string fields accept scalar types and optionals of them (§14).
Lists, dictionaries, and records do not support `==` and are not printable.

`int` and `float` share Lua's number representation; static types select the
operations and formatting. Lists, dictionaries, and records are mutable and have
reference semantics: assignment and argument passing share a value rather than
copy it. Their Lua layout is private to the runtime.

Index and field assignments evaluate the right-hand side first, then the object
expression, then the index expression, matching Python.

New operations that can fail are runtime helper calls with site IDs and follow the
emission invariants of §9.

### Completion

Each feature is complete when its examples check, build, and run; its constructs
have positive and relevant negative tests; and its runtime failures report accurate
source locations and caller frames. Where Willow agrees with Python, Python
provides an additional comparison for expected output.

## 13. Floats and division

`float` is an IEEE 754 binary64 number.

A float literal has a fractional part, an exponent, or both: `1.0`, `0.25`, `1e9`,
`2.5e-3`. Digits are required on both sides of the decimal point, and the integer
part follows the leading-zero rule for integer literals. A literal that rounds to
infinity is a compile-time error.

There is no implicit conversion between `int` and `float`, so `1 + 1.5` and
`1 == 1.0` are type errors. Two built-ins convert explicitly:

- `float(n: int) -> float` is exact, since every Willow integer is representable.
- `int(x: float) -> int` truncates toward zero. NaN, infinity, and results outside
  the integer range raise `cannot convert float to int`.

`+`, `-`, `*`, and unary operators on floats follow IEEE 754 with round-to-nearest.
Float results may be infinite or NaN; there is no overflow check. `-0.0` is a
distinct float that prints as `-0.0`, and `-0.0 == 0.0` is `True`.

Division operators require two operands of the same type:

| Operator | `int` operands | `float` operands |
| --- | --- | --- |
| `/` | `float` quotient | `float` quotient |
| `//` | `int`, floor of the quotient | `float`, floor of the quotient |
| `%` | `int` remainder | `float` remainder |

The remainder has the sign of the divisor, and `(a // b) * b + a % b == a` for
integers. A zero divisor, including `-0.0`, raises `division by zero` for every
operator. Results match Python: `7 // -2` is `-4`, `7 % -2` is `-1`, `-7.5 // 2.0`
is `-4.0`, and `1 / 3` is `0.3333333333333333`. Integer `//` and `%` always stay
within the integer range.

Ordering comparisons accept two integers or two floats. NaN is unequal to every
value, including itself, and every ordering comparison with NaN is `False`.

`print` writes a float as Python's `repr` does: the shortest decimal text that
reads back as the same value; scientific notation when the decimal exponent is below
-4 or at least 16, and otherwise fixed notation with at least one fractional digit;
and `inf`, `-inf`, or `nan` for non-finite values.

```python
def main() -> None:
    print(7 / 2)        # 3.5
    print(7 // 2)       # 3
    print(-7 % 3)       # 2
    print(0.1 + 0.2)    # 0.30000000000000004
    print(1e16)         # 1e+16
    print(float(3))     # 3.0
    print(int(-2.7))    # -2
```

## 14. Optional types

`T | None` holds either a value of `T` or `None`. `T` is any type other than `None`
or another optional: `str | None`, `list[int] | None`, `Node | None`. Other unions,
including `None | T` and `int | str`, are errors. `None` is `nil` in generated Lua.

`T` and `None` are assignable to `T | None` in initializers, assignments,
arguments, returns, display elements, and constructor arguments. This widening does
not change the value's representation, and no other implicit conversion exists.

A local's lexically first assignment fixes its type, from the annotation if present
and otherwise from the initializer. Every later assignment must be assignable to
that type. This replaces the first slice's same-type rule. An optional local
therefore needs an annotation:

```python
best: str | None = None
```

An optional value can be assigned, passed, returned, compared, printed, and tested
with `is None` or `is not None`. Arithmetic, conditions, indexing, field access, and
method calls require narrowing it to `T` first. Implicit truthiness remains a type
error.

`is` appears only as `expression is None` or `expression is not None`, where the
expression has an optional type. Other uses of `is` are errors. `==` and `!=`
accept two operands when one operand's type is assignable to the other's, so
`count == 3` and `count == None` are valid for `count: int | None`.

### Narrowing

A local or parameter narrows to `T` where a check proves it is not `None`. Each
condition yields facts that hold when it is true and facts that hold when it is
false:

- `name is not None` narrows `name` when true; `name is None` narrows it when false.
- `not C` swaps the facts of `C`.
- `A and B` narrows with the true facts of both operands when true. `B` is checked
  with the true facts of `A`.
- `A or B` narrows with the false facts of both operands when false. `B` is checked
  with the false facts of `A`.
- Other conditions yield no facts.

Field and index expressions do not narrow; copy them into a local first. Facts flow
through statements like definite assignment (§6):

- An `if` or `elif` branch starts with the true facts of its condition and the
  false facts of the conditions before it. An `else` branch, or the implicit empty
  branch of an `if` without one, starts with the false facts of every condition.
- After an `if`, a local is narrowed if it is narrowed at the end of every branch
  that falls through, including the implicit empty branch.
- A `while` body starts with the true facts of its condition.
- An assignment narrows a local when the assigned value has a non-optional type
  other than `None`, and ends its narrowing otherwise.
- At the start of a loop body and after the loop, narrowing from before the loop
  holds only for locals the body does not assign.

```python
def describe(name: str | None) -> str:
    if name is None:
        return "anonymous"
    return "user " + name

def main() -> None:
    count: int | None = None
    print(describe(None))           # anonymous
    print(describe("ada"))          # user ada
    if count is not None and count > 0:
        print(count)
    print(count)                    # None
```

## 15. Lists, dictionaries, and `for`

`list[T]` is an ordered sequence of `T` values. `dict[K, V]` maps keys of type `K`
to values of type `V`, where `K` is `int` or `str`. Element and value types can be
any type. Collection types are invariant: `list[int]` is not assignable to
`list[int | None]`, although a display can be checked against either type.

```python
numbers = [1, 2, 3]                     # list[int]
ages = {"ada": 36, "alan": 41}          # dict[str, int]
names: list[str] = []
scores: dict[str, int | None] = {"ada": None}
```

A display with an expected type, from an annotation, an existing target, a
parameter, a return type, a field, or an enclosing display, checks each element
against that type, and an empty display takes that type. Without an expected type,
a non-empty display takes the types of its first element or entry, later ones must
be assignable to them, and an empty display is an error.

List displays evaluate elements left to right. Dict displays evaluate each key and
then its value, entry by entry. A repeated key keeps its first position and its
last value.

Collections store `None` elements and values. A stored `None` counts toward length
and is distinct from a missing key.

| Expression | Type | Meaning |
| --- | --- | --- |
| `len(xs)` | `int` | Number of elements |
| `xs[i]` | `T` | Element at index `i` |
| `xs[i] = v` | | Replace the element at index `i` |
| `xs.append(v)` | `None` | Add `v` at the end |
| `xs.pop()` | `T` | Remove and return the last element |
| `v in xs` | `bool` | Some element equals `v` |
| `len(d)` | `int` | Number of entries |
| `d[k]` | `V` | Value for key `k` |
| `d[k] = v` | | Insert or replace the entry for `k` |
| `d.get(k)` | `V \| None` | Value for `k`, or `None` when missing |
| `d.pop(k)` | `V` | Remove the entry for `k` and return its value |
| `k in d` | `bool` | `k` is a key |

`not in` negates `in`. List indexes are zero-based integers with
`0 <= i < len(xs)`; any other index, including a negative one, raises
`list index out of range`. Lists have no slicing. `pop()` on an empty list raises
`pop from empty list`. `d[k]` and `d.pop(k)` raise `key not found` for a missing key.
When `V` is already optional, `d.get(k)` has type `V`; use `in` to tell a stored
`None` from a missing key. `v in xs` requires an element type that supports `==`.

Dictionaries keep insertion order. Replacing a value keeps the entry's position,
and a key removed and inserted again moves to the end.

### `for` loops

`for name in iterable:` runs its body once per item of a list (elements in index
order), a dictionary (keys in insertion order), a string (§17), or a `range` call:

- `range(stop)`, `range(start, stop)`, and `range(start, stop, step)` take integers
  and produce the same sequence as Python. A zero step raises
  `range step must not be zero`. `range` appears only as a `for` iterable.
- The iterable and the `range` arguments are evaluated once, before the first
  iteration.
- The loop name is a function local (§6). Each iteration assigns it an item, so the
  item type must be assignable to the local's type, and the loop fixes that type
  when it is the lexically first assignment.
- Assigning the loop name in the body does not affect iteration. After the loop, the
  name keeps its last value, but the loop does not make it definitely assigned.
- List iteration visits each index while it is below the list's current length, so
  appended elements are visited.
- Adding or removing a dictionary's keys while iterating over it raises
  `dictionary changed size during iteration` at the next step. Replacing values is
  allowed.

```python
def main() -> None:
    totals: dict[str, int] = {}
    for word in ["a", "b", "a"]:
        if word in totals:
            totals[word] = totals[word] + 1
        else:
            totals[word] = 1
    for word in totals:
        print(word)                 # a, then b
        print(totals[word])         # 2, then 1
    for i in range(3, 0, -1):
        print(i)                    # 3, 2, 1
```

## 16. Records

A `class` declaration at file scope defines a record type. Its body holds one or
more field declarations of the form `name: Type`, and nothing else.

```python
class Node:
    value: int
    next: Node | None

def total(head: Node | None) -> int:
    result = 0
    node = head
    while node is not None:
        result = result + node.value
        node = node.next
    return result

def main() -> None:
    print(total(Node(1, Node(2, Node(3, None)))))   # 6
```

Records share the file-level namespace with functions and built-in names, and
duplicates are errors. Field names are unique within a record. Field types may name
any record, including the record itself and records declared later.

Calling a record by name constructs a value. The constructor takes one positional
argument per field, in declaration order, with exact arity; each argument must be
assignable to its field's type. Arguments are evaluated left to right.

`p.x` reads a field and `p.x = v` replaces it; `v` must be assignable to the field's
type. Naming an unknown field is an error. Records are nominal: two records with
the same fields are different types. A local that shares a record's name shadows
its constructor in that function (§6); annotations still name the record.

## 17. Richer strings

### Literals

Triple-quoted strings (`"""..."""` and `'''...'''`) may span lines. Each line break
inside one becomes `\n`, the text keeps its indentation, and escapes work as in
other strings.

Escapes add `\xhh`, `\uhhhh`, and `\Uhhhhhhhh`, each denoting the code point with
that hexadecimal value. Surrogates (U+D800 through U+DFFF) and values above U+10FFFF
are errors.

An f-string (`f"..."`, `f'...'`, or a triple-quoted form) interpolates expressions
in braces:

```python
f"{name} has {len(name)} letters"
```

Each replacement field holds one expression of a printable type (§12) and
contributes the same text as `str(...)`. Fields are evaluated left to right, and
the result concatenates the literal text and the field text. `{{` and `}}` denote
literal braces. A field cannot be empty or contain a backslash, a `#`, or the
f-string's own quote character, and a lone `}` is an error. Format specifications
(`{x:.2f}`) and conversions (`{x!r}`) are deferred.

### Operations

`str(value)` converts a printable value to the text `print` would write, without the
newline. Length, indexes, and iteration count code points.

| Expression | Type | Meaning |
| --- | --- | --- |
| `len(s)` | `int` | Number of code points |
| `a < b`, `<=`, `>`, `>=` | `bool` | Lexicographic order by code point |
| `sub in s` | `bool` | `sub` occurs in `s` |
| `s.startswith(prefix)` | `bool` | `s` begins with `prefix` |
| `s.endswith(suffix)` | `bool` | `s` ends with `suffix` |
| `s.find(sub)` | `int` | Index of the first occurrence of `sub`, or `-1` |
| `s.replace(old, new)` | `str` | Every non-overlapping `old`, left to right, replaced by `new` |
| `s.strip()` | `str` | `s` without leading and trailing ASCII whitespace |
| `s.split(sep)` | `list[str]` | Pieces of `s` between occurrences of `sep` |
| `sep.join(items)` | `str` | The `list[str]` items joined with `sep` |
| `for ch in s:` | | Each code point as a one-code-point string |

Results match Python's, except that `strip` removes only space, tab, LF, VT, FF,
and CR. `split` with an empty separator raises `empty separator`. Strings have no
indexing or slicing.

```python
def main() -> None:
    name = "Willow"
    print(f"{name} has {len(name)} letters")    # Willow has 6 letters
    words = "a, b, c".split(", ")
    print("-".join(words))                      # a-b-c
    print(f"{7 / 2} {{braces}}")                # 3.5 {braces}
```

## 18. Modules

A program is an entry file and the modules it imports, directly or indirectly. All
of them live in the entry file's directory.

```python
# geometry.wlo
class Point:
    x: float
    y: float

def distance_squared(a: Point, b: Point) -> float:
    dx = a.x - b.x
    dy = a.y - b.y
    return dx * dx + dy * dy
```

```python
# main.wlo
import geometry

def main() -> None:
    origin = geometry.Point(0.0, 0.0)
    corner = geometry.Point(3.0, 4.0)
    print(geometry.distance_squared(origin, corner))    # 25.0
```

- `import name` loads `name.wlo` from the entry file's directory. Each import
  statement names one module, and imports precede all declarations. A missing
  module file is a compile-time error at the import.
- An import binds the module name at the importing file's scope. It conflicts with
  that file's functions, records, and other imports, and a local of the same name
  shadows it (§6).
- `module.name` refers to a function or record declared in that module, in calls,
  constructors, and annotations such as `geometry.Point`. Modules are not values.
  Names that begin with `_` are private to their module.
- Imports may form cycles. Modules contain only declarations, so they have no
  initialization order. Each module loads once.
- The entry file must define `main() -> None` (§7). In other modules, `main` is an
  ordinary function name.

`check`, `run`, and `build` take the entry file and process every reachable module.
An error in any module prevents execution and build output. `build` writes one
standalone Lua file containing every module, ordered by first import in depth-first
order from the entry file. Diagnostics and runtime frames name the file each
location belongs to. The input-overwrite check of §8 covers every module.

## 19. Exceptions

The third slice adds exception classes, `raise`, and `try`. The runtime failures
of earlier sections become exceptions that programs can catch. The rules of
§1–§18 hold unless this section changes them, and completion follows §12.

```python
class ParseError(Exception):
    line: int

def parse_digit(text: str, line: int) -> int:
    index = "0123456789".find(text)
    if len(text) != 1 or index < 0:
        raise ParseError(f"not a digit: {text}", line)
    return index

def main() -> None:
    try:
        print(parse_digit("7", 1))                      # 7
        print(parse_digit("x", 2))
    except ParseError as error:
        print(f"line {error.line}: {error.message}")    # line 2: not a digit: x
    finally:
        print("done")                                   # done
```

### Exception classes

`Exception` is a built-in class with one field, `message: str`. A class that names
`Exception` as its base declares an exception class:

```python
class ParseError(Exception):
    line: int
```

Its fields are `message` followed by the declared fields, and its constructor takes
one positional argument per field in that order. The body may be `pass` instead of
fields. A declared field cannot be named `message`. The base must be `Exception`,
so exception classes form a single level beneath it. Otherwise exception classes
follow the record rules of §16, including module-qualified names such as
`parser.ParseError`.

A value of any exception class is assignable to `Exception`, which is valid in
annotations. Collections stay invariant: `list[ParseError]` is not assignable to
`list[Exception]`.

These built-in exception classes have only the `message` field:

| Class | Raised by |
| --- | --- |
| `OverflowError` | `integer overflow` |
| `ZeroDivisionError` | `division by zero` |
| `ValueError` | `cannot convert float to int`, `range step must not be zero`, `empty separator` |
| `IndexError` | `list index out of range`, `pop from empty list` |
| `KeyError` | `key not found` |
| `RuntimeError` | `dictionary changed size during iteration` |

`Exception` and these classes join `print`, `len`, and `range` as built-in names
(§12). Programs construct and raise them like their own classes. Stack exhaustion,
memory exhaustion, and output failures are not exceptions; they terminate the
program as before.

### `raise`

`raise expression` evaluates an expression of an exception type and raises the
value. The raise records its source location and the active Willow frames. A
runtime failure records the location of the failing operation instead.

A bare `raise` appears only inside an `except` clause. It raises the exception
that clause is handling again, with its original location and frames. `raise ...
from ...` is rejected.

`raise` transfers control: statements after it are unreachable, and a path that
ends in `raise` needs no `return` (§6).

### `try`

```python
try:
    statements
except ParseError as error:
    statements
except Exception:
    statements
finally:
    statements
```

A `try` has one or more `except` clauses, a `finally` clause, or both. Each `except`
names one exception class, possibly module-qualified, and may bind it with
`as name`. A bare `except:`, a parenthesized list of classes, `except*`, and an
`else` clause are rejected.

The body runs first. If it raises, the `except` clauses are tested in order, and
the first that names the exception's class or `Exception` handles it. If none
does, the exception continues to propagate. A clause after `except Exception`, or
one naming the same class as an earlier clause, is unreachable and an error.

`finally` runs however the `try` is left: by falling through, by `return`,
`break`, or `continue`, or by an exception from the body or an `except` clause.
The departure then resumes; a `return` value is evaluated before `finally` runs.
An exception raised in `finally` replaces the one in flight. `return`, `break`,
and `continue` directly inside `finally` are errors.

The `as` name is a function local (§6). The handled exception's class must be
assignable to the local's type, and the clause fixes that type when it is the
lexically first assignment. The name is definitely assigned inside its clause.

### Static flow

- The body may stop at any statement. An `except` clause therefore starts with the
  definite assignments from before the `try`, and with the narrowing from before
  the `try` only for locals the body does not assign. A `finally` clause starts the
  same way, also excluding locals the `except` clauses assign.
- After the `try`, the body and the `except` clauses join like the branches of an
  `if` with an `else` (§6, §14), counting only those that fall through. The
  `finally` clause then applies to the result as ordinary statements.
- A `try` transfers control when its body and every `except` clause transfer, or
  when its `finally` clause transfers.

### Uncaught exceptions

An exception that leaves `main` terminates the program with status 1. Its
diagnostic gives the class name before the message, at the recorded location, with
the recorded frames. Had no clause caught the `ParseError` in the example above,
the program would report:

```text
main.wlo:7:9: error: ParseError: not a digit: x
  in parse_digit at main.wlo:7:9
  called from main at main.wlo:13:15
```

Runtime failures from earlier sections report the same way, as in
`error: OverflowError: integer overflow`. Host failures keep the §10 form.

## 20. Growth without premature machinery

Preserve these boundaries now:

- Willow types and operations remain distinct from their Lua representation.
- Function signatures are collected independently from checking bodies.
- Runtime calls have explicit typed compiler definitions.
- AST and lowered nodes retain source locations.
- Scalar `None` representation does not dictate future collection storage.
- Unsupported syntax is rejected rather than assigned provisional semantics.
- Emitted runtime helpers are private implementation details.

These choices allow later work without implementing it early. A likely addition
after the third slice is a small I/O library. It should arrive with its own
semantics and examples.

Do not reserve architecture for a package manager, plugin system, optimizer,
self-hosted compiler, full Python object model, or language server. Ordinary
modules and clear pass interfaces are enough preparation.

Willow makes no promise of Python source compatibility, Python package
compatibility, or access to arbitrary Lua libraries. Its promise is narrower:
small programs that read naturally, are statically checked, and compile to
understandable Lua with predictable behavior.
