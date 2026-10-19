# Enum defaults and enum dictionary keys

## Plan

`agents/plans/2026-10-19-001-enum-defaults-and-dictionary-keys.md`

## Summary

Parameters and fields accept `E.MEMBER` and `module.E.MEMBER` defaults, and
dictionaries accept one enum type as their key. `calc.wlo` and `report.wlo`
use enums, and `examples/rosettacode/enumerations.wlo` is added. The plan's
goal is met.

## Decisions

- An enum default's spans are the member name's, as for `E.MEMBER` in
  expressions, so default errors point at the member.
- A signed dotted default such as `-E.A` stays a parse error.

## Checks run

- `make test` — 275 passed, 0 failed.

## Manual verification

1. The changed examples keep their output; the calc case below also checks
   left-associative subtraction.

   ```sh
   printf '2 * (3 + 4)\n1 / 0\n8 - 2 - 1\n' | ./willow run examples/stdlib/calc.wlo
   ./willow run examples/stdlib/report.wlo --sort=x /dev/null; echo $?
   ./willow run examples/rosettacode/enumerations.wlo | diff - examples/rosettacode/enumerations.out
   ```

   `14.0`, `division by zero`, `5.0`; the report usage error with status 2;
   no diff.
