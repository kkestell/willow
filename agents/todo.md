# TODO

Milestones and tasks for implementing the first slice described in `willow.md`.
Section numbers refer to that document.

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

- [ ] Parser (§3, §5)
  - [ ] AST nodes describing Willow with a span on every node
  - [ ] File scope holds only `def`; parameter and return annotations mandatory; trailing commas allowed; annotation types limited to `int`, `bool`, `str`, `None`
  - [ ] Statements: assignment, annotated assignment with required initializer, call statement, `return` with and without a value, `pass`, `break`, `continue`, `if`/`elif`/`else`, `while`; blocks require at least one statement
  - [ ] Non-call expression statements rejected; chained, destructuring, augmented, and walrus assignment rejected
  - [ ] Precedence levels per §5, left associative; comparison operands restricted to arithmetic level so `not a == b` parses and `a == not b` is a syntax error
  - [ ] Comparison chains rejected at parse time
  - [ ] Call targets are bare identifiers; `(f)(x)` rejected
  - [ ] Multiline expressions inside parentheses
  - [ ] Reserved words without a supported construct (`for`, `class`, `import`, `lambda`, `is`, `in`, `try`, `with`, ...) rejected explicitly

- [ ] Bind (§6, §7)
  - [ ] Collect all file-level signatures before bodies; duplicate function and parameter names are errors; defining `print` is an error
  - [ ] Require exactly one `main() -> None`
  - [ ] Per-function symbols with stable identities: parameters and every name assigned anywhere in the body are locals for the whole body, shadowing functions and `print`
  - [ ] Calling a local or parameter is a "cannot call local variable" error at any position; unknown names are errors
  - [ ] Record the resolved target on every call node

- [ ] Check (§4, §5, §6)
  - [ ] Expression types: unary `+`/`-` on `int`, `not` on `bool`, `+ - *` on `int`, `+` on `str`, `and`/`or` on `bool`, `==`/`!=` on same-typed operands of any of the four types, ordering on `int` only; conditions must be `bool`
  - [ ] Calls: exact arity, argument types match parameters, result is the return type; `print` accepts one value of any of the four types and returns `None`
  - [ ] Locals keep one type across all assignments; an explicit annotation checks the initializer and is allowed only on the lexically first assignment; annotating a parameter is an error
  - [ ] Definite assignment: join rules after `if`/`elif`/`else`, transferring branches ignored, loop-body assignments not definite after the loop
  - [ ] Control transfer: an `if` whose branches all transfer is itself a transfer; statements after a transfer are unreachable errors; non-`None` functions return on every path by structural analysis; `break`/`continue` outside a loop are errors
  - [ ] Record operation types for lowering; collect independent errors; report unexpected compiler failures as internal compiler errors

- [ ] Lower (§9)
  - [ ] Left-to-right evaluation with explicit temporaries for operands and arguments
  - [ ] Short-circuit `and`/`or` as branches
  - [ ] Checked integer `+ - *` and negation as runtime helper calls carrying a site ID
  - [ ] `return call()` assigns to a temporary before returning; every call yields exactly one value
  - [ ] `break` and `continue` as labeled loop transfers; `print` as a built-in call

- [ ] Emit and runtime (§8, §9, §10)
  - [ ] Forward-declare every user function as a local at file top; mangle user names; `__wlo_` prefix for helpers, temporaries, and labels
  - [ ] At most one user call or fallible helper call per generated line; statement temporaries wrapped in `do ... end`; loop body wrapped in `do ... end` ahead of the `continue` label
  - [ ] String literal escaping routine with round-trip tests for escapes and non-ASCII
  - [ ] Deterministic output for identical source and recorded path
  - [ ] Embedded source map from Lua line to Willow `(line, column, function)`; entry invocation of `main` after all definitions
  - [ ] Runtime helpers inlined into the output: checked integer ops rejecting non-finite and out-of-range results and normalizing `-0.0`; `print` formatting for all four types; write and flush failures reported as runtime errors
  - [ ] Structured errors `{category, message, location}`; `xpcall` handler prints `file:line:col: error: message` plus Willow caller frames, hides runtime and wrapper frames, and wraps raw VM string errors with the innermost Willow frame

- [ ] CLI (§8)
  - [ ] `check`, `run`, `build -o <path>`; unknown options and extra arguments rejected; exit 0 on success and 1 otherwise; diagnostics on stderr, program output on stdout
  - [ ] `run` compiles in memory and executes only after the full source checks
  - [ ] `build` writes a temporary sibling, flushes, and renames atomically; a failed build leaves existing output intact
  - [ ] Output paths that alias the input rejected via `ffi` `stat` device and inode comparison

- [ ] Tests and completion (§11)
  - [ ] Lexer/parser tests: indentation, tabs, blank and comment-only lines, bare CR, missing final newline, UTF-8, escapes, precedence, chained comparisons, parenthesized call targets, multiline calls, malformed blocks, unsupported syntax
  - [ ] Static tests: inference, annotations on non-first assignments, whole-function shadowing, forward calls, mutual recursion, arity, operand types, missing returns after `while True`, definite assignment, unreachable code, incompatible branch assignments, loop transfer misuse
  - [ ] Program tests: integer boundaries, overflow on each operation, `-0.0`, string round trips, `None == None` evaluation order, argument evaluation order on failure, short-circuit effects, `continue` with temporaries, more than 200 temporaries in one function, recursion, exact output, column-accurate failures on multi-call lines and return-call sites
  - [ ] CLI tests: `check` does not execute, `run` and built output agree, invalid source preserves output, input overwrite via path and symlink rejected, paths with spaces, standalone output runs outside the checkout
  - [ ] Examples check, build, and run; README covers CLI usage; exercised platforms recorded
