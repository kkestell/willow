# TODO

Milestones and tasks for implementing the slices described in `willow.md`.
Section numbers refer to that document.

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

- [ ] Records (§16)
  - [ ] Parser: `class Name:` with one or more `name: Type` fields and nothing else; file scope holds `def` and `class`; field access and field assignment targets
  - [ ] Bind: record names in the file-level namespace with functions and built-ins; duplicate record and field names rejected; forward and self references; constructors as call targets; locals shadowing constructors but not annotations
  - [ ] Check: nominal record types; constructor arity and argument assignability; field read and write types; unknown fields rejected; `==` and `print` reject records
  - [ ] Emit and runtime: records as Lua tables; constructor arguments evaluated left to right; field assignment evaluation order
  - [ ] Tests: construction, mutation through aliases, recursive records with optional fields and narrowing, constructor arity and type errors, unknown fields, field expressions that do not narrow; the §16 example

- [ ] Richer strings (§17)
  - [ ] Lexer: triple-quoted strings with line breaks as `\n` and bare CR still rejected; `\x`, `\u`, `\U` escapes with surrogates and values above U+10FFFF rejected; f-strings with `{{`, `}}`, the field restrictions, and accurate spans inside fields
  - [ ] Parser: f-string fields as expressions
  - [ ] Check: printable field types; `str(...)`; string ordering; `len`, `in`, and the §17 methods; `for` over strings
  - [ ] Runtime: one formatting routine shared by `print`, `str(...)`, and f-strings; code-point length and iteration; `startswith`, `endswith`, `find` by code-point index, `replace` including an empty `old`, ASCII `strip`, `split` raising `empty separator`, and `join`, matching Python
  - [ ] Tests: triple-quoted line endings, numeric escape boundaries, f-string evaluation order and rejections, non-ASCII length, ordering, and method results checked against Python; a strings example

- [ ] Modules (§18)
  - [ ] Parser: `import name` before declarations; `module.name` in calls, constructors, and annotations
  - [ ] Loader: resolve `name.wlo` in the entry file's directory; load each module once; allow cycles; report a missing module at its import; order modules by first import, depth first
  - [ ] Bind: a file scope per module; import name conflicts; local shadowing of module names; `_` names private to their module; `main` required only in the entry file
  - [ ] Check: collect signatures and records from every module before checking bodies
  - [ ] Emit: one standalone file for all modules; per-module name mangling; source map and site entries carrying file paths
  - [ ] CLI: `check`, `run`, and `build` process every reachable module; any module error prevents execution and output; the overwrite check covers every module
  - [ ] Tests: multi-file program fixtures, cycles, private names, missing modules, errors reported in imported files, runtime frames across files, standalone built output; the §18 example
