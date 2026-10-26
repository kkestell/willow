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

- Support amd64 — complete, but unverified on real amd64 hardware.
  - Implemented: Linux Docker test environment, `amd64_sysv` coroutine
    switching, and removal of Intel macOS support.
  - Full `make bootstrap-test` verification is deferred to real Linux amd64
    hardware. Docker Desktop's Rosetta blocks the full suite on this host;
    see [Docker setup](../docs/bootstrap.md#linux-in-docker).
  - Add PCRE2 to the Docker dependencies when `re` exists.
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
- Add SHA-256 in a new `hash` module: `hash.sha256(data: bytes) -> bytes` and
  a `Sha256` class with `update(data: bytes)`, `digest() -> bytes`, and
  `hexdigest() -> str`, tested against the NIST vectors. Decision needed:
  written in Willow after the bitwise operators (no dependency, but slow with
  masking and overflow checks), or calling a platform library (CommonCrypto on
  macOS, OpenSSL's libcrypto on Linux), or vendored C compiled into programs.

---

Future scope. Do not implement yet!

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
