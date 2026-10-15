# Review: Lists, dictionaries, and `for`

## Scope and coverage

Reviewed the staged changes for `agents/plans/2026-10-15-003-lists-dictionaries-and-for.md` against `willow.md` §12 and §15 and `AGENTS.md`: `compiler/lexer.lua`, `compiler/parser.lua`, `compiler/bind.lua`, `compiler/check.lua`, `compiler/lower.lua`, `compiler/emit.lua`, `runtime/core.lua`, the unit and program tests, `examples/collections.wlo`, and `agents/todo.md`. Also read the code the new nodes pass through: `is_pure`, `lower_operand`, `lower_short_circuit`, `spill`, the `print` and `float` builtin lowering, the loop body emission shared with `while`, and the narrowing state handling for loops.

Two departures from the plan are intended: the generated `for` header line maps to the iterator helper's span (the `range` call or the `for` keyword), so the frame for `range step must not be zero` matches the failure location; and runtime helpers that cannot fail still take the trailing site argument the emitter always passes.

## Fixed

None.

## Findings

No open findings.

## Checks run

- `make test`: `128 passed, 0 failed`.
- Ran `tests/programs/collections.wlo` and `examples/collections.wlo` under Python 3 with a `main()` call appended: output matches `collections.out` and `willow run` exactly.
- Ran every program in `examples/`: all succeed.
- Ran scratch programs: `return` and `continue` inside a `for` body (generated Lua uses the shared `do ... end` and continue label); nested `range` loops with `break`; `not in` and `in` with printing operands inside `and` (left to right, short-circuit preserved); `xs[side()] = side()` (value before index); `xs[0] = xs.pop()` on a one-element list (`list index out of range` at the index); `get` on stored and missing `None`; replacing dict values during iteration, then `pop` and reinsert order; `range` with a negative step and an empty range; an optional loop name narrowed inside the body and widened after the loop; a body assignment of an optional value clearing narrowing after the loop.
- Checked diagnostics for: the loop name used after the loop, a loop name whose existing type differs from the item type, uncalled methods, an annotation on an index target, `is None` on an index of a non-optional value, `in` on a list of lists, `in` and `not in` chains, `not a in b`, a wrong dict key type in index assignment, `range` shadowed by a local, `==` and `print` on collections.

## Verdict

The milestone meets §12 and §15. Types, displays with and without expected types, indexing, methods, `len`, `in` and `not in`, `for` over lists, dictionaries, and `range`, loop-name typing and narrowing, evaluation order, and the runtime failures with their locations and caller frames all match the specification. No findings remain open.
