# Filesystem, environment, and time

## Goal

Implement `docs/spec.md` §18: the `fs` path, directory, and metadata functions
with the `fs.Stat` record; `sys.getenv`, `sys.environ`, and `sys.getcwd`; the
compiler-provided `time` module; NUL and UTF-8 validation; and the built-in
`TimeoutError`. Deliver an environment-configured directory inventory example
that reports its elapsed time, verified on macOS and Linux. Fold §18 into the
baseline spec.

## Related code

- `compiler/bind.lua` — `M.modules` (the compiler-provided `sys` and `fs`, whose
  declarations are `Builtin` targets) and the built-in `exceptions` list.
- `compiler/check.lua` — `builtins` signatures with `names` and `defaults`; the
  `Call` branch types a builtin call by `builtin.result`.
- `compiler/lower.lua` — a builtin call lowers to `helper(name, args)`, which
  emits `__wlo_<name>(args..., site)` and records `name` in `helpers`.
- `compiler/emit.lua` — `read_runtime` and the conditional case runtime.
- `runtime/core.lua` — `__wlo_fail`, `__wlo_valid_utf8`, `__wlo_list`,
  `__wlo_dict`, `__wlo_read_file`, and the `ffi` declarations at the top.
- `compiler/cli.lua` — declares `willow_stat` and `stat` through `ffi` in the
  same process that runs `willow run` programs.
- `compiler/loader.lua` — resolves provided modules through `bind.modules`.

## Decisions

- **Native types.** No §18 API returns a native resource: `fs.Stat` is an
  ordinary record. The native-type machinery and its resource conventions land
  with their first user, the §19 file handles, and the todo sub-item moves
  there.
- **Provided declarations.** `M.modules.fs` gains the `Builtin` targets `join`,
  `basename`, `dirname`, `listdir`, `stat`, `exists`, `mkdir`, `remove`,
  `rmdir`, and `rename`, and the record `Stat`, built like the built-in
  exceptions: `{ kind = "Record", name = "Stat", type_name = "fs.Stat",
  fields = { kind: str, size: int, modified: float } }` with resolved field
  types and `types.record`. `M.modules.sys` gains `getenv`, `environ`, and
  `getcwd`. A new `M.modules.time` has `time`, `monotonic`, `sleep`, and `utc`.
  A program's own `time.wlo` shadows it, as for `sys` and `fs`.
- **Signatures.** Each new entry in check's `builtins` gives `names` from §18,
  so keywords work. `stat` defaults `follow_symlinks` to `True`; `mkdir`
  defaults `parents` and `exist_ok` to `False`. `stat` returns `Stat.type`,
  `listdir` `list[str]`, `getenv` `str | None`, and `environ`
  `dict[str, str]`.
- **Host runtime file.** New `runtime/host.lua` defines `__wlo_join` through
  `__wlo_utc`. `emit` inlines it after `runtime/core.lua` when the program uses
  any helper it defines, found by scanning its text for
  `local function __wlo_(name)`, so programs without host calls stay small and
  never declare the host structures.
- **FFI declarations.** `host.lua` declares its C functions under `__wlo_c_`
  names with `__asm__` symbols, so they cannot collide with the CLI's `stat`
  declaration in the `willow run` process. Structures:
  - `struct stat` by platform: macOS (64-bit inode layout, symbols
    `stat$INODE64` and `lstat$INODE64` on x64), Linux x64, and Linux arm64.
    Only the mode, size, and modification time are read.
  - `struct dirent`: macOS (`d_name` after `d_ino`, `d_seekoff`, `d_reclen`,
    `d_namlen`, `d_type`; `opendir$INODE64` and `readdir$INODE64` on x64) and
    Linux (`d_ino`, `d_off`, `d_reclen`, `d_type`, `d_name`).
  - `struct timespec` for `clock_gettime` (`CLOCK_REALTIME` 0;
    `CLOCK_MONOTONIC` 6 on macOS, 1 on Linux) and `nanosleep`.
  - The environment through `_NSGetEnviron()` on macOS and `environ` on Linux.
  - `getcwd`, `mkdir`, `unlink`, `rmdir`, `rename`, and `strerror`.
- **Errors.** A path or name containing NUL raises `ValueError` with
  `path contains a NUL character` (`name contains ...` for environment names).
  Host failures raise `OSError` with `cannot <operation> <path>: <strerror>`:
  `list`, `stat`, `create directory`, `remove`, `remove directory`,
  `rename <source> to`, and `get the working directory`. Returned names, values,
  and the working directory must be valid UTF-8, or the call raises `ValueError`
  `invalid UTF-8`. Invalid environment names (empty, `=`, or NUL) raise
  `ValueError` `invalid environment variable name`.
- **Behaviors.**
  - `join`, `basename`, and `dirname` follow Python's `posixpath` for two
    arguments, including `dirname` keeping an all-slash head such as `//`.
  - `listdir` skips `.` and `..` and sorts names by bytes, which is code-point
    order for UTF-8.
  - `stat` maps `S_IFMT` to `file`, `directory`, `symlink`, or `other`; a size
    above `__wlo_MAX_INT` raises `OverflowError` `file size out of range`;
    `modified` is seconds plus nanoseconds over 1e9.
  - `exists` is false for `ENOENT` and `ENOTDIR` and raises otherwise.
  - `mkdir` strips trailing slashes, creates missing parents when `parents`
    (each parent as if `exist_ok`), and with `exist_ok` accepts an existing
    path only when `stat` says it is a directory. The mode is 0777, so the
    umask applies.
  - `environ` sorts its entries by name; each entry splits at the first `=`.
  - `sleep` raises `ValueError` `sleep length must be finite and nonnegative`
    for NaN, infinities, and negatives, and restarts `nanosleep` with the
    remaining time when interrupted.
  - `utc` raises `ValueError` `timestamp out of range` outside years 1 to 9999
    or for non-finite values, floors to whole seconds, and converts days to a
    civil date with the standard days-from-epoch algorithm.
- **`TimeoutError`.** It joins the built-in `exceptions`. Nothing raises it
  until §20.

## Test plan

- `tests/unit/check_test.lua`: `fs.stat(path='x', follow_symlinks=False).kind`
  is `str`; `fs.Stat` in an annotation and constructed by keywords;
  `sys.getenv('X')` needs narrowing before `+`; `time.sleep(1)` rejected (int);
  `TimeoutError` is a built-in class; a local `time.wlo` module shadows `time`
  (`tests/modules/shadow_time/`).
- `tests/unit/emit_test.lua`: a program without host calls has no
  `__wlo_c_stat` in its output; one calling `fs.exists` does.
- `tests/programs/host.wlo` and `.out` (deterministic):
  - `join`, `basename`, and `dirname` on the Python cases: `("a", "b")`,
    `("a/", "b")`, `("a", "/b")`, `("", "b")`, `("a", "")`; `"a/b"`, `"a/b/"`,
    `"/"`, `"a"`, `"//a"`, `"a//b"`, `""`.
  - In a directory named by the program under `/tmp` with its process-specific
    name taken from `time.time()`: `mkdir` with `parents`, `exist_ok` on a
    directory and on a file (raises), `write_file`, `listdir` order with a
    non-ASCII name, `stat` kinds and sizes for a file and a directory (Willow
    cannot create symlinks, so the CLI test covers them); `exists` on a missing
    path and through a file component; `rename` replacing a file; `remove`; `rmdir` of a non-empty
    directory (raises `OSError`) and of an empty one; cleanup.
  - A path containing `\x00` raises `ValueError`.
  - `sys.getenv` of the `WILLOW` variable ends with `/willow`; a missing name
    is `None`; `getenv("A=B")` raises; `sys.environ()` contains `WILLOW` and
    changing the snapshot does not change `getenv`; `sys.getcwd()` begins with
    `/`.
  - `time.utc` of `0.0`, `-1.0`, `951782400.5` (a leap day), `-62135596800.0`,
    `253402300799.0`, and an out-of-range value; `time.sleep(0.01)` advances
    `time.monotonic()` by at least 0.01; `time.sleep(-1.0)` raises.
- `tests/unit/cli_test.lua` `listing_example`: run `examples/listing.wlo` in a
  temporary directory holding a file, a subdirectory, and a symlink, with
  `LISTING_DIR` set, and compare everything but the elapsed-time line, which
  must match its pattern; also check `fs.stat` of the symlink with and without
  following through a small program.
- Linux: run `make test` in a Linux arm64 container to confirm the `stat`,
  `dirent`, clock, and environment declarations.

## Implementation plan

1. `runtime/host.lua` with the declarations and helpers above.
2. `compiler/emit.lua`: inline `runtime/host.lua` when a helper it defines is
   used.
3. `compiler/bind.lua`: the new provided declarations, `fs.Stat`, the `time`
   module, and `TimeoutError`.
4. `compiler/check.lua`: the new `builtins` signatures.
5. Tests above, including `tests/modules/shadow_time/`.
6. `examples/listing.wlo`: reads `LISTING_DIR` (default `.`) with
   `sys.getenv`, lists the entries with kind, size, and the UTC modification
   time, prints totals per kind, and ends with the elapsed time from
   `time.monotonic()` formatted with `.3f`.
7. Verify on Linux in a container.
8. Fold §18 into `docs/spec.md` (§14 gains the new `fs`, `sys`, and `time`
   entries and the conventions; §10 lists `TimeoutError`) and update
   `agents/todo.md`, moving the native-type sub-item to §19.

## Documentation updates

- `docs/spec.md`: §14 `fs`, `sys`, and a new `time` subsection describe the new
  functions, `Stat`, NUL and UTF-8 handling, and error messages; §10 lists
  `TimeoutError`. The §18 heading stays with one sentence saying where its rules
  live; its "Native types and common conventions" subsection moves under §19,
  which first uses it. The top pointer and the milestones introduction say
  sections 19–24 are unimplemented.
- `agents/todo.md`: check off §18 and move its native-type sub-item to §19.
