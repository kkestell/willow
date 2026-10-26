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
