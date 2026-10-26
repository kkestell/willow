# Build stage 1 from compiler/

## Goal

Delete the copy of the compiler in `bootstrap/stage1/`. Stage 0 builds
`compiler/`'s modules with a small L0 driver into `willow1`, which builds
`compiler/willow.wlo` as today. A language change then updates two parsers
(stage 0's C parser and `compiler/`), not three.

## Findings

Research ran against `d4e6520`. The scratch builds are in `/tmp/mix` and
`/tmp/t2`.

- The compiler core is already L0, except for one call. `compiler/`'s ast, tokens,
  lexer, parser, types, stdlib, bind, check, emit, coroutine, diagnostic, and
  show, paired with `bootstrap/stage1/willow1.wlo` and stage 1's loader, build
  under willow0 once `check.wlo:1616` stops calling `min`. That was the only
  error.
- The resulting willow1 builds `compiler/willow.wlo` into a willow2a that emits
  IL identical to the current chain's willow2a, compared with `cmp`.
- `compiler/loader.wlo` is the one shared module outside L0. Its only non-L0
  code is the source read: `try`/`except OSError`, `fs.read_bytes`, and
  `bytes.decode` in `visit`, `read_source`, `char_size`, and `read_reason`. With
  those moved into a separate module that the bootstrap replaces with an L0
  version, the loader builds under willow0, the chain still emits identical IL,
  and `compiler/bind_test.wlo` builds and passes under willow0.
  `lexer_test`, `parser_test`, and `types_test` already do.
- Building `compiler/willow.wlo` with stage 0 directly would be a real project.
  The modules `willow`, `init`, `manifest`, and `runner`, plus the library
  modules `fs`, `io`, `json`, `subprocess`, `aio`, and `time`, use exceptions
  (about 30 `try` blocks and `class ... (Exception)`), tuple types, and async.
  Stage 0 would need exceptions and coroutines. That work is out of scope here.

## Design

Stage 1 is the `compiler/` core built by stage 0 with an L0 driver.

- `bootstrap/stage1/` keeps two files:
  - `willow1.wlo`, the existing driver, updated to the compiler's API:
    `loader.load(path, fs.read_file(path), loader.file_roots(path), true)` and
    `emitter.finish(modules[0], false)`. It can call `loader.is_identifier`
    in place of its own `is_module_name`.
  - `source.wlo`, an L0 replacement for `compiler/source.wlo`, with the same
    `Unreadable` class and a `read` that returns `fs.read_file(path)`.
    Stage 0's `fs.read_file` ends the program on failure, which is enough for
    the bootstrap.
- New `compiler/source.wlo` reads a source file. It holds:
  - `class Unreadable: reason: str`.
  - `read(path) -> str | diagnostic.Diagnostic | Unreadable`, which is today's
    `read_source` with the `OSError` caught and returned as `Unreadable`.
  - `char_size`, and `read_reason` for `manifest.wlo`.
- `compiler/loader.wlo`'s `visit` calls `source.read` and reports
  `Unreadable` as `cannot load module '{name}': {reason}`. The loader drops its
  `read_source`, `char_size`, and `read_reason`.
- `compiler/willow.wlo:124` and `:246` use `source.read` and check for
  `Unreadable` instead of using `try`. `manifest.wlo` uses
  `source.read_reason`.
- `compiler/check.wlo:1616`: compute the smaller length inline instead of
  calling `min`.
- Rule: every module that `willow1.wlo` imports, directly or transitively,
  stays in L0. Building willow1 enforces the rule, so no separate check is
  needed. The driver modules (`willow`, `init`, `manifest`, `runner`, `source`)
  and the `_files`/`_test` drivers can use the full language.

## Steps

1. Add `compiler/source.wlo`. Move the read code out of `loader.wlo`, and
   update `loader.wlo`, `willow.wlo`, and `manifest.wlo` to use it. Replace
   `min` in `check.wlo`. Run `make bootstrap-test` while stage 1 is still the
   old copy. That checks the refactor with the current chain.
2. Delete every file in `bootstrap/stage1/` except `willow1.wlo`. Add
   `bootstrap/stage1/source.wlo` and update `willow1.wlo`.
3. Makefile:
   - `STAGE1_SOURCES := $(wildcard bootstrap/stage1/*.wlo) $(STAGE2_SOURCES)`.
   - The willow1 rule runs `bootstrap/prepare.sh compiler $(BUILD_DIR)/stage1`
     and then `cp bootstrap/stage1/*.wlo $(BUILD_DIR)/stage1/`. The bootstrap
     `source.wlo` replaces the compiler's.
   - Remove `bootstrap/tests/stage1.sh` from `bootstrap-test`.
4. Delete `bootstrap/tests/stage1.sh`. Its unit tests now run as `compiler/`'s
   tests in `stage2.sh`. Its willow1 self-compile fixed point is covered by the
   willow2 fixed point, which compiles the same modules.
5. Docs:
   - `docs/bootstrap.md`: the stage table (stage 1's source is `compiler/` plus
     `bootstrap/stage1/`), the L0 paragraph (the rule above), the prepare
     description, and the `bootstrap-test` list (drop the stage 1 tests item).
   - `AGENTS.md`: the purpose paragraph, and the code style line that names
     `bootstrap/stage1/` as L0. It should now name the modules willow1 imports.
     Keep the "update each stage that parses the changed construct" rule; it
     now covers fewer parsers.
6. Run `make bootstrap-test` on macOS and on Linux (the `Dockerfile.gnat`
   image).

## Out of scope

These are stale pieces noticed during research. Leave them for separate
changes:

- `compiler/check.wlo:46` reports "stage 1 does not support … yet" from
  willow2 too.
- `compiler/stdlib.wlo`'s `modules()` returns `{}`.
- `tests/runner.wlo` still handles `NAME.stage1.err`, and no such files exist.

## Size

The change deletes about 12k lines. It adds about 40 lines (`source.wlo`
twice) and edits about 60 lines across the loader, the driver, the Makefile,
and the docs. It is a small cleanup, not a language or stage 0 change.
