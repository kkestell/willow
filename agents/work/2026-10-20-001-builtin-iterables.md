# Built-in iterables, range values, and file iteration

## Plan

`agents/plans/2026-10-20-001-builtin-iterables.md`

## Summary

Lists, dicts, strings, bytes, and tuples have `iter()` methods and satisfy
`Iterable[T]`. `range(...)` is an `Iterable[int]` value anywhere, and
`io.File.iter()` iterates lines. Built-in iterators share one run-time type that
stays exhausted after `StopIteration`. Protocol dispatch finds converters for
built-in values through `__wlo_tag`. `report.wlo` and `jsonl.wlo` loop over
their files. The plan's goal is met, and the extensible iteration milestone is
complete.

## Decisions

- `__wlo_bytes_items` moved from `runtime/bytes.lua` to `runtime/core.lua`, so
  `bytes_iter` can wrap it there, as the plan intended.
- The interim "'range' can only be used as a 'for' iterable" check test became
  type and arity checks on `range` values outside `for`.

## Checks run

- `make test`: 325 passed, 0 failed.

## Manual verification

1. `jsonl.wlo` and `report.wlo` produce the same output as their `readline`
   versions.

   ```sh
   printf '{"a": "x", "n": 1}\n{"a": "y"}\n{"a": "x"}\n' > recs.jsonl
   ./willow run examples/stdlib/jsonl.wlo a x < recs.jsonl
   printf 'INFO a\nWARN b\nINFO c\n\nERROR d\n' > log.txt
   ./willow run examples/stdlib/report.wlo log.txt
   ```

   Both matched the previous versions' output exactly.

2. Every example entry program compiles to Lua that loads. The core runtime
   gained locals, so the main chunk's 200-local limit was measured.
   `report.wlo`, the largest, still loads with 60 extra locals appended and
   fails at 70.
