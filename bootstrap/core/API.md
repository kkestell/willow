# Core API for stage 0

The functions stage 0 calls to lower the built-ins and operations of L0, and
the intrinsic layer core is written over. Every function here is
`$W.core.<name>`. Core may define other functions; stage 0 calls only these,
and stage 1 calls `os` and `run` through `import core`.

## Conventions

- A list, dict, or class value is a `ptr` to its object; core never sees its
  static type. Stage 0 converts each `word` result to the static type: `copy`
  for slot types, `cast` for `float`, and unboxing where §4 requires it.
- A union value is a `ptr`: 0 for `none`, a `str`, list, dict, or class object
  as itself, and any other scalar as a box.
- An object's header word points at its type descriptor,
  `$W.<module>.<Type>.type` or `$W.<builtin>.type`. A descriptor is
  `{ l name }`, where `name` is a `str`; an enum's descriptor continues with one
  `str` per member, in declaration order, holding its text (`Color.RED`).
- A box is a header word and a payload `word`: the `int`, the `float` bits, 0
  or 1 for `bool`, or the ordinal for an enum.
- Equality kinds, passed as `kind: int`: 0 compares slots (`int`, `bool`,
  enums, `none`), 1 compares as `float` (NaN unequal, `-0.0 == 0.0`), 2
  compares `str` by bytes, 3 compares unions with `union_eq`.
- An omitted slice start is passed as 0 and an omitted stop as
  9223372036854775807, which clamping makes the length.
- Indexes and slice bounds may be negative, as spec §7 says; core does the
  normalizing and clamping.

## Program and failures

| Signature | Meaning |
| --- | --- |
| `init()` | Called by the entry before `main`; ignores SIGPIPE |
| `fail(class_name: str, message: str)` | Writes `error: <class_name>: <message>` and a newline to stderr and exits with status 1 |

Fatal failures of L0:

| Class | Message | Raised by |
| --- | --- | --- |
| `IndexError` | `list index out of range` | `list_get`, `list_set` |
| `IndexError` | `string index out of range` | `str_index` |
| `IndexError` | `pop from empty list` | `list_pop` |
| `KeyError` | `key not found` | `dict_get`, `dict_pop` |
| `ZeroDivisionError` | `division by zero` | stage 0 inline; `float_mod`, `float_floordiv` |
| `OverflowError` | `integer overflow` | stage 0 inline |
| `ValueError` | `cannot convert float to int` | `float_to_int` |
| `ValueError` | `cannot convert str to int` | `str_to_int` |
| `ValueError` | `cannot convert str to float` | `str_to_float` |
| `ValueError` | `empty separator` | `str_split` |
| `ValueError` | `expected one character` | `str_ord` |
| `ValueError` | `invalid code point` | `str_chr` |
| `ValueError` | `range step must not be zero` | stage 0 inline |
| `ValueError` | `exit status out of range` | `sys_exit` |
| `ValueError` | `invalid UTF-8` | `sys_args`, `fs_read_file`, `fs_realpath` |
| `ValueError` | `path contains a NUL character` | `fs_read_file`, `fs_write_file`, `fs_exists`, `fs_realpath` |
| `ValueError` | `args must contain a nonempty executable name` | `run` |
| `ValueError` | `argument contains a NUL character` | `run` |
| `AssertionError` | the message, or `assertion failed` | stage 0 inline |
| `RuntimeError` | `dictionary changed size during iteration` | `dict_next` |
| `OSError` | `cannot run <program>: <reason>` | `run`, when the program cannot be found or started |
| `OSError` | `cannot read <path>: <reason>`, `cannot write <path>: <reason>`, `cannot stat <path>: <reason>`, and `cannot resolve <path>: <reason>`, where `<reason>` is the `strerror` text | `fs_read_file`, `fs_write_file`, `fs_exists`, and `fs_realpath` respectively |

## Text of values

| Signature | Meaning |
| --- | --- |
| `int_to_str(n: int) -> str` | Decimal text |
| `float_to_str(x: float) -> str` | Python `repr` text, including `inf`, `-inf`, `nan` |
| `bool_to_str(b: bool) -> str` | `true` or `false` |
| `enum_to_str(descriptor: ptr, ordinal: int) -> str` | The member's text from the enum's descriptor |
| `union_to_str(value: ptr) -> str` | The text of a printable union value; `none` for 0 |
| `print_str(s: str)` | Writes `s` and a newline to stdout; reports a failed write and exits with status 1 |
| `eprint_str(s: str)` | Writes `s` and a newline to stderr, for `sys.eprint`; exits with status 1 if the write fails |

`print(v)`, `sys.eprint(v)`, `str(v)`, and f-string fields convert `v` with
the function for its static type; a `str` is used as it is and `none` is the
literal `"none"`.

## Numbers and conversions

| Signature | Meaning |
| --- | --- |
| `float_floordiv(a: float, b: float) -> float` | `a // b`: the floor of the quotient |
| `float_mod(a: float, b: float) -> float` | `a % b`: the remainder with the sign of `b`, so `5.0 % -3.0` is `-1.0` |
| `str_to_int(s: str) -> int` | `int(s)` |
| `str_to_float(s: str) -> float` | `float(s)` |
| `float_to_int(x: float) -> int` | `int(x)`, truncating toward zero |

`float(n)` for an `int` is inline `sltof`.

## Strings

| Signature | Meaning |
| --- | --- |
| `str_concat(a: str, b: str) -> str` | `a + b`; f-strings concatenate their parts with it |
| `str_eq(a: str, b: str) -> bool` | `a == b` |
| `str_compare(a: str, b: str) -> int` | Negative, zero, or positive as `a` sorts before, equal to, or after `b` |
| `str_len(s: str) -> int` | `len(s)`, in code points |
| `str_size(s: str) -> int` | The length in bytes |
| `str_char_at(s: str, offset: int) -> str` | The code point starting at byte `offset`, for `for c in s`, which advances by its `str_size` |
| `str_index(s: str, i: int) -> str` | `s[i]` |
| `str_slice(s: str, start: int, stop: int) -> str` | `s[start:stop]` |
| `str_contains(s: str, sub: str) -> bool` | `sub in s` |
| `str_find(s: str, sub: str) -> int \| none` | `s.find(sub)` |
| `str_startswith(s: str, prefix: str) -> bool` | `s.startswith(prefix)` |
| `str_endswith(s: str, suffix: str) -> bool` | `s.endswith(suffix)` |
| `str_replace(s: str, old: str, new: str) -> str` | `s.replace(old, new)` |
| `str_strip(s: str) -> str` | `s.strip()` |
| `str_split(s: str, sep: str \| none, maxsplit: int) -> ptr` | `s.split(sep, maxsplit)` as a `list[str]`; stage 0 passes `none` and -1 for omitted arguments |
| `str_join(sep: str, items: ptr) -> str` | `sep.join(items)` for a `list[str]` |
| `str_removeprefix(s: str, prefix: str) -> str` | `s.removeprefix(prefix)` |
| `str_removesuffix(s: str, suffix: str) -> str` | `s.removesuffix(suffix)` |
| `str_isdigit(s: str) -> bool` | `s.isdigit()` |
| `str_isalpha(s: str) -> bool` | `s.isalpha()` |
| `str_isalnum(s: str) -> bool` | `s.isalnum()` |
| `str_isspace(s: str) -> bool` | `s.isspace()` |
| `str_ljust(s: str, width: int) -> str` | `s.ljust(width)` |
| `str_rjust(s: str, width: int) -> str` | `s.rjust(width)` |
| `str_ord(s: str) -> int` | `ord(s)` |
| `str_chr(n: int) -> str` | `chr(n)` |

## Lists

| Signature | Meaning |
| --- | --- |
| `list_new(capacity: int) -> ptr` | An empty list; displays append their elements to it |
| `list_len(xs: ptr) -> int` | `len(xs)` |
| `list_get(xs: ptr, i: int) -> word` | `xs[i]`; `for` loops call it with indexes below the current length |
| `list_set(xs: ptr, i: int, value: word)` | `xs[i] = value` |
| `list_append(xs: ptr, value: word)` | `xs.append(value)` |
| `list_pop(xs: ptr) -> word` | `xs.pop()` |
| `list_extend(xs: ptr, items: ptr)` | `xs.extend(items)`, copying `items` first; in L0 `items` is a list, and stage 0 rejects any other argument |
| `list_reverse(xs: ptr)` | `xs.reverse()` |
| `list_slice(xs: ptr, start: int, stop: int) -> ptr` | `xs[start:stop]` |
| `list_contains(xs: ptr, value: word, kind: int) -> bool` | `value in xs`, comparing with equality kind `kind` |

## Dicts

| Signature | Meaning |
| --- | --- |
| `dict_new(key_kind: int) -> ptr` | An empty dict whose keys use equality kind 0 or 2 |
| `dict_len(d: ptr) -> int` | `len(d)` |
| `dict_get(d: ptr, key: word) -> word` | `d[key]` |
| `dict_set(d: ptr, key: word, value: word)` | `d[key] = value`; displays set their entries in order |
| `dict_contains(d: ptr, key: word) -> bool` | `key in d` |
| `dict_pop(d: ptr, key: word) -> word` | `d.pop(key)` |
| `dict_find(d: ptr, key: word) -> int` | The entry index of `key`, or -1; `d.get` reads the value with `dict_value_at` |
| `dict_version(d: ptr) -> int` | A count that every insertion of a new key and every removal increases; replacing a value leaves it unchanged |
| `dict_next(d: ptr, entry: int, version: int) -> int` | The first live entry index at or after `entry`, or -1; fails if `dict_version(d)` is no longer `version` |
| `dict_key_at(d: ptr, entry: int) -> word` | The key of a live entry |
| `dict_value_at(d: ptr, entry: int) -> word` | The value of a live entry |

`for` over a dict, `keys()`, `values()`, and `items()` record `version` as
`dict_version(d)` before the loop and step with
`dict_next(d, entry + 1, version)`.

## Boxes, unions, and classes

| Signature | Meaning |
| --- | --- |
| `box(descriptor: ptr, value: word) -> ptr` | A new box with header `descriptor` and payload `value` |
| `unbox(value: ptr) -> word` | The payload of a box |
| `is_instance(value: ptr, descriptor: ptr) -> bool` | `value` is not 0 and its header is `descriptor` |
| `union_eq(a: ptr, b: ptr) -> bool` | Union `==`: both 0, or the same descriptor and equal contents, with float boxes compared as equality kind 1 and `str` as kind 2 |
| `object_new(descriptor: ptr, fields: int) -> ptr` | A class instance with header `descriptor` and `fields` zeroed field slots |

## sys and fs

| Signature | Meaning |
| --- | --- |
| `sys_args(argc: int, argv: ptr) -> ptr` | `sys.args()` as a new `list[str]`; stage 0 passes the `argc` and `argv` its entry saved in the words `$W.argc` and `$W.argv` |
| `sys_exit(status: int)` | `sys.exit(status)` |
| `fs_read_file(path: str) -> str` | `fs.read_file(path)` |
| `fs_write_file(path: str, text: str)` | `fs.write_file(path, text)` |
| `fs_exists(path: str) -> bool` | `fs.exists(path)`: false when the path, or a symlink's target, is missing or a component is not a directory |
| `fs_realpath(path: str) -> str` | `fs.realpath(path)`, the absolute path with symlinks resolved |

## Called by stage 1

| Signature | Meaning |
| --- | --- |
| `os() -> str` | `__os`, the target's operating system |
| `run(args: list[str]) -> int` | Runs `args[0]`, searched for in `PATH`, with the remaining arguments and no shell, through the shared `process_start` helper using `posix_spawn`; the child inherits stdin, stdout, stderr, and the environment, with SIGPIPE's default action. Waits and returns the exit status, or 128 plus the signal number if a signal ended the child |

## Exceptions under stages 1 and 2

Programs that stages 1 and 2 compile raise exceptions instead of ending. The
word `$W.pending` holds the pending exception, or 0. Stages 1 and 2 compile
their own body for `fail`, which creates the exception with `failure` and
stores it in `$W.pending`. An exception object is a header, its location and
frames, both `str` and 0 until it is raised, and its fields, `message` first.
The frames are the report's lines after the first, each starting with a
newline. The exception reporting functions run with `$W.pending` cleared.

| Signature | Meaning |
| --- | --- |
| `fail_at(class_name: str, message: str, path: str, line: int, col: int)` | Like `fail`, with a location independent of the first recorded frame |
| `failure(descriptors: ptr, class_name: str, message: str) -> ptr` | A new exception of the built-in class named `class_name`, whose descriptor is in the array `descriptors`, `$W.exceptions` |
| `raised(e: ptr, function: str, path: str, line: int, col: int)` | Starts the frames of `e`, raised by a `raise` statement in `function` at the location |
| `trace(e: ptr, function: str, path: str, line: int, col: int)` | Adds the frame `in function at path:line:col` to `e`, or `called from` after the first, which also sets the location |
| `report(e: ptr)` | Writes the spec §13 report of an exception that left `main` to stderr |

## Coroutines under stages 1 and 2

`CoroutineContext` is an internal core class; its field order is shared with
the low-level helpers and switch assembly in `compiler/coroutine.wlo`. An entry
is a raw function address taking one `word` argument and returning no value.
Generator and async lowering supply the addresses and slot conversions. Async
tasks use one context per scheduled task; direct coroutine awaits run on that
task's stack.

| Signature | Meaning |
| --- | --- |
| `coroutine_create(entry: ptr, argument: word) -> CoroutineContext` | Creates an unstarted coroutine; unsupported in stage 0 and on amd64 |
| `coroutine_resume(coroutine: CoroutineContext) -> word` | Runs until yield or completion, returning the yielded slot or 0 on completion; transfers a callback failure to the caller's pending exception |
| `coroutine_yield(value: word)` | Suspends the running coroutine and returns to its resumer |
| `coroutine_finished(coroutine: CoroutineContext) -> bool` | Whether the entry has returned, normally or with an exception |

Resuming a finished coroutine returns 0 again. Resuming a running coroutine
or yielding outside one raises `RuntimeError`. A callback failure is transferred
once; generator advancement converts an escaping `StopIteration` to `RuntimeError`.
Switches run with no pending exception. Finished contexts release their stack
references after switching to the caller.

## Async under stages 1 and 2

A `Coroutine[T]` is a header pointing at `$W.Coroutine.type`, a body closure
pointer, and a consumed flag. The body closure has its code address at byte 8
and bound arguments and environment from byte 16, as emitted function closures
do. The code takes that closure and returns a `word`, including 0 for `none`.
Creating the object does not allocate a stack or execute its body. Consuming it
sets the flag and clears its body reference; aliases share the flag.

| Signature | Meaning |
| --- | --- |
| `async_coroutine(body: ptr) -> ptr` | Wrap a deferred body closure in an unconsumed coroutine |
| `async_consume(coroutine: ptr) -> ptr` | Mark consumed and return the body, or raise for a repeated consumption |
| `async_await(coroutine: ptr) -> word` | Consume and invoke the body on the current task's stack |
| `aio_run(body: ptr) -> word` | Run a coroutine as the root task; return its outcome or transfer its exception to the caller |
| `aio_sleep_coroutine(seconds: float, path: str, line: int, col: int) -> ptr` | Create a sleep coroutine; validate when it runs, reporting this creation site |

The loop is L0 over `clock_gettime` with `CLOCK_MONOTONIC` (1 on Linux, 6 on
Darwin) and `poll`. It runs FIFO ready batches, polls between batches, and
orders timers by deadline then wait ID. An ended wait invalidates its timers.
The loop holds references to suspended tasks, and finished contexts release
their stacks through `coroutine_resume`.

`AioTask`'s fields follow its header: context, body, result, error, wait ID,
state, scope, group, waiters, interruptible, and start location. State is 0
(running), 1 (done), 2 (failed), or 3 (cancelled). The low-level `aio_resume`
helper uses the context at byte 8 and error at byte 32 to capture a task failure
without unwinding the scheduler. `aio_loop` and `aio_set_loop` access the
running loop, rooted by `$W.aio.loop`. Public `aio.Task`, `aio.TaskGroup`, and
`aio.Semaphore` values wrap the core `AioTask`, `AioGroup`, and `AioSemaphore`
objects in their first fields; await and group-scope lowering unwrap them.
The loop polls descriptor interests alongside timers, using wait IDs to discard
registrations after readiness, timeout, or cancellation.

| Signature | Meaning |
| --- | --- |
| `aio_wait_fd(fd: int, events: int, deadline: float \| none) -> bool` | Suspend until readiness or deadline, checking cancellation before and after waiting |
| `aio_close_fd(fd: int, loop: AioLoop \| none)` | Remove registrations and wake operations before closing; also works outside a loop |
| `aio_task_group() -> AioGroup` | Create an inactive group |
| `aio_group_enter(group: AioGroup)` | Enter a single-use group and install its cancellation scope |
| `aio_group_exit(group: AioGroup, error: ptr) -> ptr` | Join children; return the first final failure, an outer cancellation, or 0 |
| `aio_group_start(group: AioGroup, coroutine: ptr, path: str, line: int, col: int) -> AioTask` | Check admission, consume, and queue a child without running it inline |
| `aio_group_cancel(group: AioGroup)` | Request an idempotent stop while active |
| `aio_task_result(task: AioTask) -> word` | Return the outcome without waiting |
| `aio_await_task(task: AioTask) -> word` | Check cancellation, wait if needed, and return the outcome |
| `aio_semaphore(value: int) -> AioSemaphore` | Create a positive, bounded permit count |
| `aio_semaphore_acquire(semaphore: AioSemaphore) -> ptr` | Create a coroutine that acquires a permit at a checkpoint |
| `aio_semaphore_wait(semaphore: AioSemaphore)` | Acquire a permit, suspending at a checkpoint when unavailable |
| `aio_semaphore_release(semaphore: AioSemaphore)` | Hand a permit to the first live waiter or return it to the count |

`$W.aio.cancel` is a pending control-transfer marker, outside `Exception`.
Requests remain on the originating groups and follow each task's scope chain.
`aio_checkpoint` delivers a request; `aio_request` wakes interruptible waits
in wait-ID order, using the loop's insertion-ordered waiting dictionary. Joins
are uninterruptible and keep waiting for child cleanup. Async finally bodies
and resource exits save and clear the current scope and restore it on both
normal and exceptional departure. `aio_exception` maps cancellation to 0 for
plain resource exits.

A group records only its first final body or child failure. At task completion,
a child failure's frames end with its start location; `trace` leaves that
terminal traceback unchanged when handles or groups observe it again. Finished
tasks clear body and waiter references; `coroutine_resume` releases their stacks.
Semaphore waiters remember a granted permit so cancellation after handoff can
return it without leaking or overtaking another waiter.

## Inline in stage 0

Integer and float arithmetic and comparisons with their overflow and division
checks, `and`, `or`, `not`, `range` loops, `is` type tests on a
non-union, field loads and stores, `float(n)` for an `int`, and `assert`.

## Intrinsics

Only core may use these.

| Form | Meaning |
| --- | --- |
| `ptr` | A raw address; `none` is not assignable to it |
| `word` | An uninspected 8-byte slot |
| `__alloc(size: int) -> ptr` | `GC_malloc`: zeroed, scanned memory |
| `__alloc_atomic(size: int) -> ptr` | `GC_malloc_atomic`: unzeroed memory the collector does not scan |
| `__load1(p: ptr, offset: int) -> int` | The byte at `p + offset`, zero-extended |
| `__store1(p: ptr, offset: int, value: int)` | Stores the low byte of `value` |
| `__load4(p: ptr, offset: int) -> int` | The 4-byte integer at `p + offset`, sign-extended |
| `__store4(p: ptr, offset: int, value: int)` | Stores the low 4 bytes of `value` |
| `__load8(p: ptr, offset: int) -> word` | The slot at `p + offset` |
| `__store8(p: ptr, offset: int, value: word)` | Stores a slot |
| `__word(x) -> word` | Reinterprets an `int`, `float`, `bool`, `ptr`, `str`, union, or other reference value |
| `__int(w: word) -> int`, `__float(w: word) -> float`, `__bool(w: word) -> bool`, `__ptr(w: word) -> ptr`, `__str(w: word) -> str` | Reinterprets a slot |
| `__type(T) -> ptr` | The descriptor of `T`: `int`, `float`, `bool`, `str`, `list`, or `dict` |
| `__addr_is_null(p: ptr) -> bool` | `p` is 0 |
| `a == b`, `a != b` on two `ptr` | Address equality, as in comparing a header with `__type(T)` |
| `__dtosi(x: float) -> int` | QBE `dtosi`: `x` truncated toward zero, unspecified outside the `int` range; `float_to_int` checks the range first |
| `__offset(p: ptr, n: int) -> ptr` | `p` moved by `n` bytes; address arithmetic is not overflow-checked as int arithmetic is |
| `__os` | `"linux"` or `"darwin"`, folded at compile time |
| `extern def name(params) -> R` | A C function; parameters and results are `int` or `ptr` (QBE `l`), `float` (`d`), or `cint` (`w`); a trailing `...` makes it variadic |
