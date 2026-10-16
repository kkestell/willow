# Keep optional runtime helpers within LuaJIT's local limit

## Goal

Fix F1 in `agents/reviews/2026-10-16-011-compiler.md`: programs combining
standard-library features must load and execute without exceeding LuaJIT's
200-local limit merely because their optional runtimes are included.

## Related code

- `compiler/runtime.lua`: `optional_runtime` currently declares each library's
  exported helpers outside its block; `text` combines those blocks; `load`
  returns helpers for use by the compiler.
- `compiler/emit.lua`: the `Helper` and `Pure` expression branches spell runtime
  function references in generated Lua.
- `compiler/lexer.lua` and `compiler/manifest.lua`: consumers of `runtime.load`
  for core UTF-8 helpers and optional JSON parsing, respectively.
- `runtime/*.lua`: optional libraries call their own helpers and core helpers;
  they currently have no references to exports from other optional libraries.
- `tests/unit/emit_test.lua` and `tests/unit/cli_test.lua`: existing emission,
  selective runtime inclusion, and temporary-program execution tests.

## Decisions

Use one local table named `__wlo_runtime` to hold optional runtime exports.
Declare each optional library's helper locals inside its existing `do` block,
then assign them to fields of `__wlo_runtime` before closing that block. For
example, the generated wrapper for bytes has this shape:

```lua
local __wlo_runtime = {}
-- Core runtime remains in its current scope.
do
  local __wlo_bytes, __wlo_bytes_concat -- remaining exports follow
  -- Existing bytes runtime text, including its helper definitions.
  __wlo_runtime.bytes = __wlo_bytes
  __wlo_runtime.bytes_concat = __wlo_bytes_concat
  -- Remaining exports follow.
end
```

The existing declaration scan supplies both the local names and table fields.
Keep those names in source order so output stays deterministic. Each library
retains its internal lexical references, including calls between exported
helpers. Their closures survive through the table, but their local slots no
longer remain active while subsequent library blocks are compiled. Runtime
source files need no edits.

Core helpers retain their existing local names. Optional libraries retain their
current inclusion conditions and order. The table contributes one outer local
regardless of how many optional helpers are selected.

Add `runtime.reference(name)`, taking an unprefixed helper name. It returns
`__wlo_runtime.<name>` for an optional export and `__wlo_<name>` for a core
helper. Build the optional-export lookup from the existing declaration scan.
Use this same function for generated helper calls and `runtime.load` return
expressions. Preserve `runtime.load`'s existing arguments, including its
`__wlo_`-prefixed requested names, so lexer and manifest callers need no changes.

## Implementation plan

1. Modify `compiler/runtime.lua`:
   - Move optional helper declarations inside their library blocks.
   - Append table assignments for each export before the block ends.
   - Emit the single `__wlo_runtime` table before optional blocks.
   - Add `reference` using the scanned optional-export names.
   - Translate requested names in `load` through `reference`, stripping their
     existing `__wlo_` prefix first.
   - Update the assembly comments to explain the scope and export table.
2. Modify `compiler/emit.lua` so `Helper` and `Pure` expressions obtain the
   callee through `runtime.reference`. Preserve argument order, site arguments,
   and source-map construction.
3. Modify `tests/unit/emit_test.lua` with a focused `runtime.load` regression
   that requests and calls both a core helper and an optional helper in the
   same load. Check their results, exercising the interface used by the lexer
   and manifest reader. Retain the existing selective-inclusion tests.
4. Modify `tests/unit/cli_test.lua` with one combined-runtime program and its
   test-entry variant, using the existing temporary-directory helpers. Exercise
   the commands and behavior described below.

## Test plan

- The combined program executes assertions using all seven optional runtime
  groups: filesystem path joining, standard-stream flushing, CLI argument
  parsing, HTTP URL encoding, JSON parsing/dumping, bytes construction/decoding,
  and Unicode case conversion. Use deterministic inputs and no network requests
  or stdin reads. CLI argument parsing should exercise calls between helpers in
  the same library.
- Run that program through `willow run`, compile it and execute the resulting
  Lua, then build it and execute the resulting executable. Each must exit
  successfully with the same small expected output and no diagnostics.
- Run the same exercise through a `test_*` entry with `willow test`. This checks
  combined runtime loading alongside the test footer's additional locals.
- The `runtime.load` regression must return working core and optional functions
  together; for example, code-point counting and JSON parsing.
- Existing diagnostic tests continue to check source locations, and existing
  emission tests continue to check deterministic output and omission of unused
  optional runtimes.
