# Standard protocols and protocol bounds review

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-19-019-standard-protocols.md`: the built-in `Iterable`,
`Iterator`, `ContextManager`, and `Generator` declarations in
`compiler/stdlib.lua`, their reservation in `compiler/lexer.lua` and parsing in
`compiler/parser.lua`, their resolution and the protocol bounds in
`compiler/bind.lua`, the new tests, and `examples/stdlib/shapes.wlo`. Traced
how the declarations flow through type checking, inference, protocol dispatch
lowering, and emission, and compared the method signatures against the spec's
standard protocol table.

Gaps:

- Built-in values satisfying these protocols, `iter`/`next`, `for` over
  iterables, generators, and `with` are later milestones and were not
  reviewed.

## Summary

| ID | Severity | Category    | Fix   | Title                                                    |
| -- | -------- | ----------- | ----- | -------------------------------------------------------- |
| F1 | High     | Correctness | Fixed | Inference through `Iterable[T]` overflows the stack      |

## F1. Inference through `Iterable[T]` overflows the stack

High · Correctness · Fixed · `compiler/check.lua:451`

Calling a generic function whose parameter is a standard protocol over its
type parameter, such as `def first[T](xs: Iterable[T]) -> T` called with a
user iterator class, crashes the compiler with "internal compiler error: stack
overflow". `collect` matches a protocol against an argument method by method,
and `Iterator[T].iter` returns `Iterator[T]` while the class's `iter` returns
the class, so matching the result repeats the same pair without end.

The recursion is in inference code that predates this change and affects any
self-referential generic protocol, but `Iterator` is self-referential by the
spec, so this change makes the crash reachable from the most ordinary use of
the new protocols.

### Evidence

`def first[T](x: Iterable[T]) -> T: return x.iter().next()` with
`print(first(Count(7)))` overflowed the stack in `collect`
(`check.lua` recursing through its protocol branch). A user-declared
`protocol It[T]` with `iter(self) -> It[T]` reproduced the same crash.

### Fix

`collect` keeps the protocol and argument pairs it is matching, keyed by type
name like `satisfies` in `types.lua`, and skips a pair already in progress.
`tests/unit/check_test.lua` now infers `T` through `Iterable[T]` from a
counter class and reports the inferred `int` against a `str` annotation.

## Checks run

- Ad hoc programs: protocol bounds on generic classes, functions, and
  `T: Iterable[int]`; standard protocols in aliases, generic aliases, unions,
  fields, and list elements; a built-in `str` against a protocol bound (rejected
  as specified). All behaved as expected apart from F1.
- `./willow run examples/stdlib/shapes.wlo 3x4 2x2.5 r1` printed both shape
  kinds and the total; `./willow run examples/stdlib/shapes.wlo r` reported
  `r: not a number` and exited with status 2.
- `make test`: 321 passed, 0 failed.

## Verdict

The standard protocols and protocol bounds match the plan and the spec. F1,
a compiler crash when inferring type arguments through the self-referential
`Iterator`, is fixed and covered by a regression test.
