# Subprocess execution and control

## Goal

Implement `docs/spec.md` §20: the `subprocess` module with `run` (inherited or
captured output, input, `cwd`, `env`, timeout) returning a `Result` record, and
`spawn` returning a native `Process` with `poll`, `wait`, `terminate`, and
`kill`. Children start without a shell, find their executable through the
child's `PATH`, receive the ordinary `SIGPIPE` disposition, and never deadlock on
pipes. Deliver a command-wrapper example and fold §20 into the baseline spec.

## Related code

- `compiler/bind.lua` — `provided`, `M.modules`, the `stat` record and native
  `file` declarations.
- `compiler/check.lua` — `builtins`, `method_signature`, `builtin_params`,
  `bind_args`.
- `compiler/lower.lua` — builtin calls lower to `helper(node.target.name, ...)`.
- `runtime/host.lua` — the platform `ffi` declarations, `__wlo_host_error`,
  `__wlo_check_path`, the environment and clock helpers.
- `runtime/io.lua` — `io.File` handles (`file`, `mode`, `closed`).
- `runtime/core.lua` — `__wlo_read_line`, `SIGPIPE` suppression,
  `__wlo_flush_streams`, and `__wlo_run`, whose name a `run` helper would take.

## Decisions

- **Declarations.** `M.modules.subprocess` provides `run` and `spawn`, the
  record `Result` (`returncode: int`, `stdout: bytes | None`,
  `stderr: bytes | None`), and the native `Process` (`prefix = "process"`) with
  `poll() -> int | None`, `wait(timeout: float | None = None) -> int`,
  `terminate()`, and `kill()`. A provided builtin may name its runtime helper in
  `helper`; lowering uses `node.target.helper or node.target.name`, so `run` and
  `spawn` call `__wlo_process_run` and `__wlo_process_spawn` and leave
  `__wlo_run` alone.
- **Method defaults.** Method tables may carry `defaults` like builtins, and
  `method_signature` returns the method entry's `names` and `defaults` so
  `bind_args` fills `wait`'s `timeout` with `None`.
- **Runtime placement.** The process helpers join `runtime/host.lua`, which
  already holds the platform declarations, the environment snapshot, the clock,
  and the error helpers they need. Getting a descriptor from an `io.File` uses
  LuaJIT's conversion of a file to its `FILE *` (`ffi.cast("void *", file)`)
  and `fileno`.
- **Launching.** `posix_spawn` with file actions (`adddup2` for each redirected
  stream and `addchdir_np` for `cwd`, available on macOS 10.15+, glibc 2.29+,
  and musl) and spawn attributes with `POSIX_SPAWN_SETSIGDEF` for `SIGPIPE`.
  The opaque attribute and file-action objects are 512-byte aligned buffers.
  Pipes are made with `pipe` and both ends marked `FD_CLOEXEC`, so only the
  `dup2` copies reach the child. A name without `/` is searched in the `PATH`
  of the child's environment (or `/usr/bin:/bin`) with `access(X_OK)`; a miss is
  `OSError` `cannot run <name>: No such file or directory`, and a
  `posix_spawn` error is `cannot run <name>: <strerror>`. Before launching,
  stdout, stderr, and any supplied writable `io.File` are flushed; a failure is
  `OSError` `cannot write <path>: <reason>` and nothing runs.
- **Validation (`ValueError`).** `args must contain a nonempty executable name`;
  `argument contains a NUL character`; environment names as in `sys.getenv`;
  NUL in environment values and `cwd`; `timeout must be finite and positive`;
  `stdin must be open for reading`, `stdout must be open for writing`,
  `stderr must be open for writing`, and closed handles as in `io`; and
  `stdin has buffered input` for a supplied `stdin` that has been read through
  stdio and, when seekable, whose `ftell` position differs from its descriptor's
  `lseek` position, or, when not seekable, was read at all. Core records files
  read through `__wlo_read_line` in a weak table, and `io.lua` records
  `read`.
- **Communication.** `run` with input or capture sets the parent's pipe ends
  non-blocking and loops on `poll` in slices of at most 50 ms: it writes pending
  input (closing the pipe when done or on `EPIPE`), reads available output, and
  checks `waitpid(WNOHANG)`. Once the child has exited, it reads what the pipes
  already hold without waiting and closes them, so descendants that inherited
  the pipes cannot hold it up. Without pipes it waits in the same sliced loop.
- **Timeouts.** The deadline uses the monotonic clock. On expiry `run` kills the
  child with `SIGKILL`, reaps it, closes the pipes, and raises `TimeoutError`
  `command timed out after <timeout> seconds`; `wait` raises
  `TimeoutError` `process did not exit within <timeout> seconds` and leaves it
  running.
- **Statuses.** A normal exit gives its code; a signal gives the negative signal
  number. `Process` caches its collected status, so `poll` and `wait` agree, and
  `terminate` and `kill` do nothing once it is collected.

## Test plan

- `tests/unit/check_test.lua`: `subprocess.run(['x'], capture_output=True)`
  typed `subprocess.Result`; `r.stdout` narrowing from `bytes | None`;
  `p.wait(timeout=1.0)` is `int`; `p.wait(1)` rejected (int); constructing
  `subprocess.Process()` rejected; `subprocess.run('x')` rejected.
- `tests/programs/subprocess.wlo` and `.out`, using `printf`, `cat`, `sh -c`,
  `env`, `pwd`, and `sleep`:
  - Literal arguments with spaces and `$` reach `printf` unchanged; captured
    binary output including `\0` and `\377`; empty capture is empty bytes.
  - Nonzero exit status; a signal exit (`sh -c 'kill -TERM $$'`) is `-15`.
  - `input` piped through `cat`; empty input; 1 MB of input through `cat` with
    capture (no deadlock); a child that ignores its input (`true`) with large
    input returns normally.
  - `cwd` (`pwd` prints the directory), `env` replacing the environment (`env`
    prints exactly the given variables), `PATH` from the given environment
    (a `PATH` without `/bin` and `/usr/bin` makes `printf` unfindable).
  - Missing executable `OSError`; empty `args` and NUL `ValueError`s; invalid
    timeout `ValueError`.
  - `run(['sleep', '5'], timeout=0.2)` raises `TimeoutError` quickly.
  - `spawn(['sleep', '5'])`: `poll()` is `None`, `wait(timeout=0.1)` raises,
    `terminate()` then `wait()` is `-15` and `poll()` agrees, and `kill()` after
    collection does nothing.
  - `spawn` with `stdout` set to an `io.File` opened with `w` writes the child's
    output to the file; a read-only file for `stdout` raises `ValueError`.
  - Output printed before a child runs appears before the child's inherited
    output.
- `tests/unit/cli_test.lua`: a child launched while Willow ignores `SIGPIPE`
  still dies of it (`sh -c 'yes | head -n 1'` exits normally rather than
  looping); a `stdin` handle read with `readline` from a pipe is rejected;
  `wrap_example`: run `examples/wrap.wlo` on `printf` with binary output, on a
  failing command, and on a command that outlives the timeout, comparing the
  reports, and check no helper process survives.

## Implementation plan

1. `compiler/bind.lua`: `subprocess` declarations, `Result`, native `Process`,
   and `helper` names; `compiler/check.lua`: `run`, `spawn`, method defaults;
   `compiler/lower.lua`: `node.target.helper`.
2. `runtime/core.lua`: record files read through `__wlo_read_line`;
   `runtime/io.lua`: record `read`.
3. `runtime/host.lua`: the process declarations and helpers.
4. Tests above.
5. `examples/wrap.wlo`: `wrap <seconds> <command> [args...]` starts a
   background helper with `spawn(["sleep", "60"])`, runs the command with
   `capture_output=True` and the timeout, prints its status and its output as
   text when it decodes and as a byte count otherwise, reports a timeout, and
   terminates and waits for the helper in `finally`.
6. Verify on Linux in a container.
7. Fold §20 into `docs/spec.md` (§14 gains `### subprocess`) and check off the
   milestone in `agents/todo.md`.

## Documentation updates

- `docs/spec.md`: `### subprocess` in §14 with the functions, `Result`,
  `Process`, launching, communication, timeout, status, and error rules; the §20
  heading keeps one sentence saying where its rules live; the top pointer and
  milestones introduction say sections 21–24 are unimplemented.
- `agents/todo.md`: check off §20.
