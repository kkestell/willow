# Compile and build executables

## Goal

Rename the `build` command to `compile`; it keeps writing one standalone Lua
file. Add a new `build` command that performs the same checks and writes a
self-contained executable: a copy of a small native stub with LuaJIT linked in,
followed by the generated Lua. The executable runs without Willow, LuaJIT, the
source files, or a source checkout.

## Related code

- `compiler/cli.lua` — argument parsing, the alias check (`same_file`), the
  atomic write (`write_output`), and the `build` branch at the end. `compile` is
  also the name of the local function that checks and emits; it becomes
  `translate` so the command name has one meaning.
- `runtime/stub.c` — prototype stub (untracked). It reads its own executable
  through `_NSGetExecutablePath` on macOS and `/proc/self/exe` on Linux, finds
  the trailer, and runs the payload with `luaL_loadbuffer`.
- `Makefile` — builds the pinned LuaJIT, which also produces
  `vendor/luajit/src/libluajit.a`.
- `runtime/core.lua:5` — frames are matched by comparing `debug.getinfo`
  sources against the chunk's own source, so any chunk name works.
- `runtime/core.lua:556` — uncaught failures exit with `os.exit(1)`, which the
  stub passes through unchanged.
- `tests/unit/cli_test.lua` — CLI tests that drive the launcher in a temporary
  directory whose path contains a space.

## Decisions

- **Commands.** `compile <file> -o <output>` is today's `build`, unchanged.
  `build <file> -o <output>` requires `-o` the same way. Both run the input and
  module alias checks and write through `write_output`. Usage:

  ```text
  usage: willow check <file>
         willow run <file>
         willow compile <file> -o <output>
         willow build <file> -o <output>
  ```

  The missing-output reason becomes `<command> needs -o <output>`.
- **Executable layout.** The executable is the bytes of `runtime/stub`, then the
  generated Lua source, then an 8-byte little-endian payload length and the
  8-byte magic `WILLOWLU`. The payload stays Lua source, as §8 requires for
  generated output. Appending data keeps the stub's ad-hoc signature valid
  enough to execute on macOS arm64, so no `codesign` step is needed.
- **Stub.** `runtime/stub.c` creates a Lua state, opens the standard libraries,
  loads the payload with chunk name `=program`, and calls it. A load or
  uncaught Lua error prints `error: <message>` and exits 1; the generated code's
  own failure handling already exits 1 for Willow runtime failures. Stub errors
  (cannot locate or read its executable, missing trailer) print `error: ...`
  and exit 1.
- **Building the stub.** `make` links `runtime/stub.c` statically against
  `libluajit.a` into `runtime/stub` (gitignored), with `-lm -ldl` on Linux and
  `MACOSX_DEPLOYMENT_TARGET=11.0` on macOS, matching LuaJIT. `make test` depends
  on it. `willow build` reads `<root>/runtime/stub`; if it cannot be opened it
  fails with `error: <io.open message>`.
- **Permissions.** `write_output(output, text, mode)` takes an optional mode;
  `build` passes `0755` and `chmod`s the temporary file through `ffi` before the
  rename. `mode_t` is `uint16_t` on macOS and `uint32_t` on Linux, declared
  beside the existing `stat` declarations.

## Test plan

In `tests/unit/cli_test.lua`:

- Rename the existing `build` cases to `compile` (`build_matches_run` becomes
  `compile_matches_run`, and so on), and update `USAGE` and the usage-error
  cases: `compile a.wlo` and `build a.wlo` report `<command> needs -o <output>`;
  replace the `compile x.wlo` unknown-command case with another unknown name.
- `build_matches_run`: build the existing two-line program (prints 42, then
  overflows) to `out file`, copy the executable to a separate directory, run it
  there, and compare exit status, stdout, and stderr with `run`. Confirm no
  `.tmp` file remains.
- `modules_build_matches_run`: build the two-module program and run the
  executable from elsewhere; building onto a module path is rejected.

## Implementation plan

1. `runtime/stub.c`: keep the prototype; add `<stdint.h>`.
2. `Makefile`: add `STUB := runtime/stub` with its link rule depending on
   `runtime/stub.c` and `$(LUAJIT)`; add it to `all` and `test`; remove it in
   `clean`. Add `/runtime/stub` to `.gitignore`.
3. `compiler/cli.lua`: accept `compile` and `build`, both taking `-o`; rename the
   local `compile` to `translate`; give `write_output` the mode argument and the
   `chmod` declaration; for `build`, read the stub and write
   `stub .. text .. length .. "WILLOWLU"` with mode `0755` (decimal 493).
4. `tests/unit/cli_test.lua`: the tests above.

## Documentation updates

- `willow.md` §8: list `compile` and `build` in the interface; describe
  `compile` as writing one standalone Lua file and `build` as writing a
  self-contained executable that needs no LuaJIT installation; apply the
  failed-output, atomic-write, and alias rules to both. Rename the "Build
  output" paragraph to compiled output.
- `willow.md` §9 layout: add `runtime/stub.c`. §11 CLI cases and §18 module
  processing: name `compile` and `build`.
- `README.md` usage: add `willow compile` and the new `willow build`, and note
  that `make` also builds the executable stub.
