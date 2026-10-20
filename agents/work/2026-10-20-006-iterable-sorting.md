# Iterable sorting and tuple ordering

## Plan

`agents/plans/2026-10-20-006-iterable-sorting.md`

## Summary

`sorted` accepts any `Iterable[T]`, collecting it into a new list before
sorting, and `sorted` and `list.sort` order comparable tuples
lexicographically. NaN anywhere in an element, including inside tuples, raises
`cannot sort NaN` before anything is reordered. `for` and `sorted` share the
iterable check and the iterator lowering. The report, listing, and kv server
examples sort their dictionaries directly, and the Rosetta example sorts its
dictionary without copying keys. The plan's goal is met.

## Checks run

- `make test`: 335 passed, 0 failed.
- `./willow test examples/stdlib/kv`: 3 passed, 0 failed.

## Manual verification

1. The updated examples print what their previous versions printed.

   ```sh
   ./willow run examples/stdlib/report.wlo log2.txt              # and with --sort count
   ./willow run examples/stdlib/listing.wlo .                    # in a fixed directory
   ./willow run examples/rosettacode/associative_array_iteration.wlo
   ```

   Each output matched the previous version's, except for listing's elapsed
   time line.
