# TODO

## For every task

- The spec states every observable behavior. Where it is silent, choose the
  simplest behavior that is fast and consistent with the rest of Willow, and
  write it into the spec. Implementation choices stay in the code. Python is a
  source of ideas, not a rule.
- For a change in behavior, change `docs/spec.md` first, then the
  implementation in every stage that parses or compiles the construct
  (AGENTS.md).
- Add conformance programs with expected output for the new behavior and its
  errors.
- `make bootstrap-test` passes on macOS arm64 and Linux arm64, and, once amd64
  support lands, on Linux amd64 in Docker (`docker run --platform linux/amd64`).

---

- Support amd64. Do this first: the other tasks are tested on it.
  - Add a way to run `make bootstrap-test` in a Linux amd64 Docker container
    with QBE 1.3, libgc, pkg-config, and the libraries the tests load: libcurl,
    and PCRE2 once `re` exists.
  - Write the `amd64_sysv` coroutine switch in `compiler/coroutine.wlo`;
    creating a coroutine on amd64 now fails with
    `coroutines require arm64 and stage 1 or 2`, and the async conformance
    programs need it.
  - Decision needed: Intel macOS cannot run in Docker. Either drop it, or fix
    `fs.stat` and `fs.listdir`, which use the arm64 `stat` and `dirent`
    layouts and unsuffixed symbols where x86_64 needs the `$INODE64` entry
    points, without a machine to test on. Recommended: drop it.
- Add integer bitwise operators and integer literal prefixes. `fs.chmod`'s
  mode wants `0o` literals, and a SHA-256 written in Willow would need the
  operators.
  - Binary `&`, `|`, `^`, `<<`, and `>>`, and unary `~`, on `int` operands
    only. They act on the 64-bit two's-complement value. A result of -2^63,
    which is outside the `int` range, raises `OverflowError` with the message
    `integer overflow`, as `~9223372036854775807` does.
  - A negative shift count raises `ValueError` with the message
    `negative shift count`. `a << n` is `a * 2**n` and raises `OverflowError`
    when that is out of range. `a >> n` is the floor of `a / 2**n`, so a count
    of 63 or more gives `0` or `-1`.
  - Precedence, from lowest: comparisons, `|`, `^`, `&`, `<<` and `>>`, then
    binary `+` and `-`. Unary `~` binds like unary `+` and `-`. Comparison
    operands may be bitwise expressions, so `x & mask == 0` means
    `(x & mask) == 0`. Update §5's precedence list and its operand rule.
  - `is` still takes a single type name, so `x is int | none` stays an error
    (`unsupported operator '|'`). `items[i | j]` is an index; test it.
  - Integer literals with `0x`, `0o`, and `0b` prefixes. The prefix is
    lowercase; hex digits may be either case. Underscores stay unsupported,
    and a literal outside the `int` range is an error.
- Add text operations.
  - `s.count(sub) -> int`: the number of non-overlapping occurrences, counted
    from the left. `s.count("")` is `len(s) + 1`, since the empty string
    occurs at every index from 0 through `len(s)`.
  - `s.rfind(sub) -> int | none`: the index of the last occurrence, or `none`.
    `s.rfind("")` is `len(s)`.
  - `s.partition(sep)` and `s.rpartition(sep)` return
    `tuple[str, str, str]`: the text before the first (or last) occurrence,
    the separator, and the text after it. Without an occurrence, `partition`
    gives `(s, "", "")` and `rpartition` gives `("", "", s)`. An empty
    separator raises `ValueError` with the message `empty separator`.
  - `int(text: str, base: int) -> int` for bases 2 through 36, positional
    like the other intrinsics. The text is an optional sign and one or more
    digits valid in the base, using `a` through `z` in either case for 10
    through 35. No prefixes, underscores, or whitespace. Bad text, or a result
    outside the `int` range, raises `ValueError` with the message
    `cannot convert str to int`; a base outside 2 through 36 raises
    `ValueError` with the message `invalid base`.
  - Format specifications become `[alignment][0][width][.precision][type]`.
    Types `x` and `X` write an `int` in lowercase or uppercase hexadecimal,
    with a leading `-` for negative values and no prefix. A `0` followed by a
    width that starts with a nonzero digit is the zero flag; a lone `0` is
    still a width of zero. The flag pads with zeros between the sign and the
    digits, as in `-0042`. It requires a value whose static type is `int` or
    `float` and a type of `d`, `f`, `x`, `X`, or none, and cannot be combined
    with an alignment; anything else is a compile-time error. Non-finite
    floats are padded with spaces instead. A precision still requires type
    `f`.
- Add regular expressions in a new `re` module, built on PCRE2
  (`libpcre2-8`).
  - `re.compile(pattern: str, ignore_case: bool = false,
    multiline: bool = false, dotall: bool = false) -> Pattern` and
    `re.escape(text: str) -> str`. Patterns use PCRE2's own syntax.
  - Compile in UTF mode with `PCRE2_NEVER_BACKSLASH_C`, since `\C` matches
    one byte and would split a code point, and `PCRE2_NEVER_UCP`, so `(*UCP)`
    cannot override the ASCII classes. Set LF as the newline.
  - `Pattern` methods: `search(text, start: int = 0) -> Match | none`,
    `match(text, start: int = 0) -> Match | none` (anchored at `start`),
    `fullmatch(text, start: int = 0) -> Match | none` (anchored at `start` and
    the end of `text`), `findall(text) -> list[str]` (the whole matches),
    `finditer(text) -> list[Match]`, `sub(replacement: str, text) -> str`, and
    `split(text, maxsplit: int = -1) -> list[str]` (captures are not included;
    `maxsplit` as in `str.split`). A `start` outside 0 through `len(text)`
    raises `IndexError` with the message `start out of range`.
  - `sub` replaces every match using PCRE2's replacement syntax (`$1`,
    `${name}`, `$$`). An unset group gives empty text
    (`PCRE2_SUBSTITUTE_UNSET_EMPTY`). A malformed replacement, or one that
    names a group the pattern lacks, raises `ValueError` with the message
    `invalid replacement`.
  - `Match` methods: `group(index: int = 0) -> str | none`,
    `named(name: str) -> str | none`, `groups() -> list[str | none]`, and
    `start` and `end` (each `(index: int = 0) -> int | none`). An unmatched
    group gives `none`; a group the pattern lacks raises `IndexError` with the
    message `no such group`. All offsets are in code points.
  - Matches are found left to right without overlapping. After an empty
    match, the next match may not be empty at the same position.
  - `\d`, `\w`, `\s`, and `\b` are ASCII only, matching the ASCII-only
    `isdigit` and friends; `.` matches one code point other than LF unless
    `dotall` is set; `ignore_case` folds Unicode case.
  - An invalid pattern raises `ValueError` with the message
    `invalid pattern at <offset>: <PCRE2's message>`, the offset in code
    points. PCRE2's text varies between versions, so tests check only the part
    before it. Exceeding PCRE2's match, depth, or heap limit raises
    `RuntimeError` with the message `regex match limit exceeded`. If the
    library can't be loaded, `OSError` with the message
    `cannot load PCRE2: <reason>`, as `http` does for libcurl.
  - Load the library with `dlopen` as `http` loads libcurl: on Linux
    `libpcre2-8.so.0`; on macOS `libpcre2-8.0.dylib` from `/opt/homebrew/lib`,
    then `/usr/local/lib`. No JIT. Free match data after each call; compiled
    patterns are not freed. Add PCRE2 to the README's requirements and to
    `Dockerfile.gnat`.
- Expose missing OS operations.
  - `fs.chmod(path: str, mode: int) -> none` (following symlinks),
    `fs.symlink(target: str, link: str) -> none`, and
    `fs.readlink(path: str) -> str`, raising `OSError` with the messages
    `cannot change mode of <path>: <reason>`,
    `cannot create link <link>: <reason>`, and
    `cannot read link <path>: <reason>`.
  - `sys.chdir(path: str) -> none`, raising `OSError` with the message
    `cannot change directory to <path>: <reason>`, and `sys.getpid() -> int`.
  - `time.utc_offset(timestamp: float) -> int`: seconds east of UTC in the
    system's local time zone at `timestamp`. It accepts the same range as
    `time.utc` and raises the same `timestamp out of range` error outside it.
  - `File.seek(position: int) -> none` (bytes from the start) and
    `File.tell() -> int`: the position of the next byte the program reads or
    writes, counting buffered data. Seeking flushes pending writes and
    discards buffered input. A negative position raises `ValueError` with the
    message `negative seek position`. A file that cannot seek, such as a pipe,
    raises `OSError` with the message `cannot seek <path>: <reason>`, using
    the standard handles' paths as other I/O errors do.
  - Signal handling. Decision needed: Willow code cannot run inside a C
    signal handler because of the GC, so a signal must be delivered at a safe
    point. Options: handlers that run at the next safe point; SIGINT raising
    an exception; or `await signals.wait(...)` integrated with the event loop
    through a self-pipe, with a blocking form for programs without tasks.
    Recommended: the last, for SIGINT, SIGTERM, and SIGHUP, with the default
    action unchanged for a signal nobody waits on.
- Add SHA-256 in a new `hash` module: `hash.sha256(data: bytes) -> bytes` and
  a `Sha256` class with `update(data: bytes)`, `digest() -> bytes`, and
  `hexdigest() -> str`, tested against the NIST vectors. Decision needed:
  written in Willow after the bitwise operators (no dependency, but slow with
  masking and overflow checks), or calling a platform library (CommonCrypto on
  macOS, OpenSSL's libcrypto on Linux), or vendored C compiled into programs.
- Decide whether to allow user `extern` declarations so external libraries can
  provide C-backed capabilities without expanding the standard library. Open:
  which types they may use (`ptr`, `cint`, and `word` are
  standard-library-only now), what that does to memory safety, and how
  libraries are found (`dlopen`, or link flags declared in `willow.json`).
- `willow run` should pass a program argument that is not valid UTF-8 through
  unchanged, so the program raises `ValueError` from its own `sys.args()` as a
  built executable does.
- A failed write to stdout or stderr reports `cannot write output: <reason>`;
  add the source location of the `print` or `sys.eprint` call. It stays a
  failure that cannot be caught.
- `subprocess`'s async methods check child status every 10 ms. Wait for the
  child's exit through the event loop instead, with a SIGCHLD self-pipe. Do
  this after signal handling, which builds the same mechanism.
- The checker reports only the first error in a program. Not a task until
  there is a goal: how many errors, how to suppress cascades, and how `.err`
  tests would match several.
