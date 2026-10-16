# Bytes and streaming I/O

## Goal

Implement `docs/spec.md` §19: the `bytes` type, native library types with
built-in methods, the `io` module with `io.File` handles for files and the
standard streams, shared buffering with `input` and `print`, flushing standard
streams at exit, and broken pipes reported as errors rather than signals.
Deliver a bounded-chunk binary copier and a JSONL filter, and fold §19 into the
baseline spec.

## Related code

- `compiler/lexer.lua` reserved words and `compiler/parser.lua` `type_names`,
  `expression_starts`, the conversion-call branch of `parse_primary`, and the
  `isinstance` class name.
- `compiler/types.lua` — scalar types, `SCALARS`, `printable`, `same`.
- `compiler/bind.lua` — `SCALARS` for annotations, `M.modules` and `provided`,
  `stat` as the model for a provided record.
- `compiler/check.lua` — `binary_types`, the `==` rule, `index_types`, the
  `Index`, `Slice`, `IndexAssign`, `MethodCall`, `Call`, and `For` branches,
  `STRING_METHODS`, `method_signature`, `bind_args`, `builtins`.
- `compiler/lower.lua` — `binary_helpers`, `prefix`, `instance_kind`, the `==`
  lowering through `pure("equal")`, and the `For` iterator.
- `compiler/emit.lua` — `optional_runtime` and `optional_runtimes`.
- `runtime/core.lua` — `__wlo_equal`, `__wlo_isinstance`, `__wlo_len`,
  `__wlo_input`, `__wlo_write`, `__wlo_exit`, `__wlo_run`, `__wlo_fail`.

## Decisions

- **Bytes representation.** A bytes value is `{ __wlo_octets = s }` with `s` a
  Lua string, so it differs from `str` in unions and `isinstance`.
  `__wlo_isinstance` reports `bytes` for it; `__wlo_equal` compares two bytes
  values by content and a bytes value with anything else as unequal;
  `__wlo_len` returns `#value.__wlo_octets`.
- **Bytes typing.** `types.bytes` is a new scalar (`kind = "bytes"`), not
  printable. `types.comparable(t)` holds when every member is printable or
  `bytes`; the `==`/`!=` rule uses it instead of `printable`. `bytes + bytes`
  is `bytes`. Indexing a `bytes` value gives `int`, slicing gives `bytes`, `for`
  gives `int`, and `len` accepts it. `IndexAssign` rejects it as it does `str`.
  `bytes` joins the lexer's reserved words, the parser's `type_names` and
  `expression_starts`, the conversion-call kinds, bind's `SCALARS`, and check's
  `builtins` as `bytes(values: list[int]) -> bytes`. `str.encode()` returns
  `bytes` and `bytes.decode()` returns `str`.
- **Bytes runtime.** New optional runtime `runtime/bytes.lua` defines
  `__wlo_bytes` (raising `ValueError` `bytes must be in range(0, 256)`),
  `__wlo_bytes_concat`, `__wlo_bytes_index` (`IndexError`
  `index out of range`), `__wlo_bytes_slice` (reusing `__wlo_slice_bounds`),
  `__wlo_bytes_items`, `__wlo_str_encode`, and `__wlo_bytes_decode`
  (`ValueError` `invalid UTF-8`). Lowering adds `bytes_concat` to
  `binary_helpers` and routes `==`/`!=` through `pure("equal")` when either side
  has a `bytes` member, as it already does for boxed floats.
- **Native types.** A native type is a provided record with no fields,
  `native = true`, a `prefix` for its helper names, and a `methods` table of
  `{ params, names, result }`. It reuses the record machinery for annotations,
  unions, `isinstance`, storing, and the existing rejection of `==` and
  printing. Check rejects calling it with `cannot construct native type io.File`
  and gives `method_signature` the methods, whose parameter names bind keywords
  through `bind_args`. Lowering's `prefix` returns `record.prefix .. "_"` for a
  native record, so `f.read(n)` calls `__wlo_file_read(f, n, site)`.
- **`io` module.** `M.modules.io` provides `open`, `stdin`, `stdout`, and
  `stderr` and the native `File` (`type_name = "io.File"`, `prefix = "file"`)
  with `read(size: int) -> bytes`, `readline() -> str | None`,
  `write(data: bytes) -> None`, `write_text(text: str) -> None`,
  `flush() -> None`, and `close() -> None`. `open` takes
  `mode: str = "r"`.
- **`io` runtime.** New optional runtime `runtime/io.lua`. A handle is
  `{ __wlo_record = "io.File", file, path, mode, borrowed, closed }`, shared by
  every alias. The standard handles wrap `io.stdin`, `io.stdout`, and
  `io.stderr`, so they share C stdio buffers with `input`, `print`, and
  `sys.eprint`, and `print`'s flush after each line keeps the order of output.
  Messages:
  - `ValueError`: `invalid mode 'x'`, `I/O operation on closed file`,
    `file is not open for reading` / `writing`, `read size must be positive`,
    `cannot close a standard stream`, and `invalid UTF-8` from `readline` after
    it consumed the line.
  - `OSError`: `cannot open <path>: <reason>`, `cannot read <path>: <reason>`,
    `cannot write <path>: <reason>`, and `cannot close <path>: <reason>`, with
    `<stdin>`, `<stdout>`, and `<stderr>` as the paths of the standard handles.
  `close` marks the handle closed before closing the file, so a failure still
  invalidates it; closing again does nothing.
- **Shared line reading.** Core's `__wlo_read_line(file)` returns a line with
  its `\n` and a `\r` before it removed, or nil at end of input, plus Lua's
  error; `__wlo_input` and `__wlo_file_readline` both use it, then validate
  UTF-8.
- **Exit and broken pipes.** Core ignores `SIGPIPE` through `ffi` (`signal(13,
  SIG_IGN)`), so writing to a closed pipe fails with `EPIPE` and follows the
  existing error rules. `__wlo_flush_streams()` flushes `io.stdout` and
  `io.stderr` and, on failure, writes `error: cannot write output: <reason>` to
  stderr and exits with status 1. `__wlo_run` calls it after `main` returns and
  before reporting an uncaught exception; `__wlo_exit` calls it before
  `os.exit`. Unclosed owned files are not closed at exit.

## Test plan

- `tests/unit/check_test.lua`: `bytes` annotations, display-free construction
  with `bytes([1])`, `+`, `==`, `len`, index (`int`), slice (`bytes`), `for`
  (`int`), `encode`/`decode`; rejected: `print(b)`, `f"{b}"`, `str(b)`,
  `b < b`, `b + "a"`, `b[0] = 1`, `dict[bytes, int]`, `bytes = 1` (reserved);
  `bytes | str` union `==` against `str` allowed; `io.File()` rejected;
  `f.read(size=4)` typed `bytes`; `f.name` rejected; `f == f` and `print(f)`
  rejected; `isinstance(v, io.File)` narrowing.
- `tests/programs/bytes.wlo` and `.out`: construction and out-of-range
  `ValueError`; length; concatenation; equality and inequality, including
  `bytes | str` holding each member against a `str`; negative index and
  out-of-range `IndexError`; slices; iteration; `encode` of non-ASCII text and
  `decode` round trip; invalid `decode` raising `ValueError`; `isinstance`.
- `tests/programs/streams.wlo`, `.in`, and `.out`: `input()` and
  `io.stdin().readline()` alternating over the same stdin with an empty line
  and a final unterminated line, then `read(4)` after a line read, then EOF
  (`None` and empty bytes); `print` and `io.stdout().write_text` interleaved in
  order; a file written with `w`, appended with `a`, read back with `read` and
  `readline`; wrong-mode, nonpositive size, closed-handle, and close-borrowed
  `ValueError`s; idempotent `close`; a missing file `OSError`; a final
  `write_text` without a newline followed by `sys.exit(0)` still appears.
- `tests/programs/streams_invalid_utf8.wlo`, `.in`, and `.out`: `readline`
  raises `ValueError` for an invalid line and the next `readline` returns the
  following line.
- `tests/unit/cli_test.lua`:
  - Broken pipe: a program printing many lines piped into `head -n 1` exits
    with status 1 and `cannot write output: Broken pipe` on stderr, not a
    signal; a program writing to `io.stdout()` in a loop catches the `OSError`.
  - `copy_example`: copy a binary file containing every byte value through
    `examples/copy.wlo` and compare; a missing source reports the `OSError`.
  - `jsonl_example`: pipe JSONL records through `examples/jsonl.wlo` with a
    field and value and compare the kept lines; an invalid line reports its
    line number.

## Implementation plan

1. `compiler/types.lua`, lexer, parser, `bind.lua`: `bytes` as a type and
   conversion name.
2. `compiler/check.lua` and `compiler/lower.lua`: bytes typing and lowering.
3. `runtime/bytes.lua`; `runtime/core.lua` changes to `__wlo_equal`,
   `__wlo_isinstance`, `__wlo_len`, `__wlo_read_line`, `SIGPIPE`, and
   `__wlo_flush_streams`.
4. `compiler/bind.lua`, `check.lua`, and `lower.lua`: native types and the `io`
   module.
5. `runtime/io.lua`; add both new files to `optional_runtimes` in `emit.lua`.
6. Tests above.
7. `examples/copy.wlo` (copy `args[0]` to `args[1]` in 65536-byte chunks with
   nested `try/finally`, as in the spec) and `examples/jsonl.wlo` (read stdin
   lines with `readline`, parse each with `json.parse`, write the line to
   `io.stdout()` when the object's `args[0]` field equals `args[1]` as text,
   holding only the current record).
8. Fold §19 into `docs/spec.md` and update `agents/todo.md`.

## Documentation updates

- `docs/spec.md`: §4 lists `bytes` among types and its equality rule; §7 gains a
  `### Bytes` subsection; §11 lists `bytes(...)`; §14 gains `### io` with the
  native-type conventions, `io.File`, buffering, exit flushing, and broken pipes,
  and `sys.exit` says it flushes the standard streams. The §19 heading stays with
  one sentence saying where its rules live. The top pointer and milestones
  introduction say sections 20–24 are unimplemented.
- `agents/todo.md`: check off §19.
