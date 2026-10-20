# Built-in iterables, range values, and file iteration

## Goal

Second task of the extensible iteration milestone (spec §3 Standard protocols,
§8 `for`, §14 `io`):

- Lists, dicts, strings, bytes, and tuples have an `iter()` method returning a
  fresh `Iterator[T]` of their items (dict keys, one-code-point strings, byte
  values, tuple items), under the existing rules: a list iterator visits
  appended elements, a dict iterator raises `RuntimeError` `dictionary changed
  size during iteration`. They satisfy `Iterable[T]` and other protocols
  declaring only `iter`.
- An exhausted built-in iterator stays exhausted, raising `StopIteration` with
  an empty message on every later `next`.
- `range(...)` is a value of type `Iterable[int]` usable anywhere; each `iter`
  starts a fresh traversal. A zero step raises its `ValueError` when `range` is
  called.
- `io.File.iter() -> Iterator[str]` reads lines through `readline`, sharing the
  file position and leaving the file open.
- `report.wlo` and `jsonl.wlo` use `for line in file` instead of `readline`
  loops.

`for` statements over lists, dicts, strings, bytes, tuples, and literal
`range(...)` calls keep their direct lowering, which has the same behavior.

## Related code

- `compiler/types.lua`: `method`, `assignable` (protocol targets accept record
  and protocol sources), `items`.
- `compiler/stdlib.lua`: standard protocols, native types (`native_record`),
  `io.File` methods, and the `range` built-in (`range = {}`).
- `compiler/check.lua`: `method_signature`, `iteration`, the `Call` branch
  (rejects `range` outside `for`), and the `For` range path.
- `compiler/lower.lua`: `conversion`, the `MethodCall` and built-in `Call`
  lowering, the `For` range path, and `converters`/`M.lower`, which build
  dispatch entries from classes and imported native types.
- `compiler/emit.lua`: `Dispatch` reads `__wlo_record or __wlo_class`.
- `runtime/core.lua`: `__wlo_list_items`, `__wlo_dict_items`,
  `__wlo_str_items`, `__wlo_tuple_items`, `__wlo_range`; `runtime/bytes.lua`
  `__wlo_bytes_items`; `runtime/io.lua` `__wlo_file_readline`.

## Decisions

- **One run-time iterator type.** Every built-in iterator is
  `{ __wlo_record = "iterator", step = f }`, where `f` is one of the existing
  `for` step functions. `__wlo_iterator_next` calls `f` until it reports the
  end, then marks the iterator done and raises `StopIteration`;
  `__wlo_iterator_iter` returns the iterator. `list_iter`, `dict_iter`,
  `str_iter`, `bytes_iter`, `tuple_iter`, and `range_iter` wrap the matching step
  function. Errors a step function raises (dict size changes) use the site of
  the `iter` call that created it.
  `bytes_iter` is in `runtime/core.lua`, so dispatch tables do not pull in the
  bytes runtime.
- **Range values** are `{ __wlo_record = "range", start, stop, step }`, made by
  `range_value`, which checks the step. `range(...)` outside a `for` header has
  type `Iterable[int]`; its argument checks are shared with the `for` path.
- **Static signatures.** `types.method` gives list, dict, str, bytes, and tuple
  values an `iter` method returning `Iterator[item]`, marked generic so
  protocol satisfaction passes it through. `Iterator[...]` is built through
  `types.iterator`, a constructor `stdlib.lua` installs because `types.lua`
  cannot require `stdlib.lua`. `assignable` lets those kinds satisfy
  protocols. `check.lua`'s `method_signature` uses it for `xs.iter()`, which
  lowers to the `<kind>_iter` helper. `io.File` gets
  `iter = { params = {}, result = Iterator[str] }`, lowered to `file_iter` in
  `runtime/io.lua`.
- **Dispatch tags.** Lists, dicts, strings, bytes, and tuples carry no tag
  field, so dispatch reads the tag through `__wlo_tag(value)`: `"str"` for a
  string, else `__wlo_record`, `__wlo_class`, `"tuple"`, `"bytes"`, `"list"`
  (has `n`), or `"dict"`.
- **Dispatch entries.** `stdlib.lua` lists run-time types for dispatch as
  native-like declarations, with no user-visible names: `list`, `dict`, `str`,
  `bytes`, `tuple`, and `range` with `iter`, and `iterator` with `iter` and
  `next`, their results typed by a type parameter. `lower.lua` adds them to the
  candidates for every dispatch table. `types.method` marks native parameter
  and result types that mention a type parameter as generic, so their
  converters are the helpers themselves.
- **Tuples as protocol values.** A tuple's items can mix `int` and `float`
  positions, whose representations differ, and the tuple records neither. A
  tuple converted to a protocol type is copied into its item type's
  representation, as `for` already does, by a tuple step in `lower.conversion`
  for a protocol target. `xs.iter()` on a tuple does the same before calling
  `tuple_iter`. Tuples have no identity, so the copy is unobservable.

## Test plan

- `tests/unit/check_test.lua`:
  - `[1, 2]`, `(1, 2.5)`, `"ab"`, `{"a": 1}`, and `range(3)` are assignable to
    `Iterable[int]`, `Iterable[int | float]`, `Iterable[str]`, `Iterable[str]`,
    and `Iterable[int]`;
  - `xs: Iterable[str] = [1]` reports "expected Iterable[str], received
    list[int]"; `x: list[int] | Iterable[int]` reports an overlap;
  - `s: str = range(3)` reports "expected str, received Iterable[int]";
    `range(1, 2, 3, 4)` and `range("a")` report the existing errors outside
    `for`.
- `tests/programs/builtin_iteration.wlo` and `.out`:
  - `iter`/`next` over a list, dict, string with a non-ASCII code point, bytes,
    and a `tuple[int, float]` (the float item prints and tests as a float);
  - one `range(3, 0, -1)` value looped twice, `range(0)` empty, and
    `range(1, 2, 0)` raising `ValueError` at the call;
  - a list appended to during iteration through an `Iterator`, and an exhausted
    iterator raising `StopIteration` twice, even after another append;
  - a dict iterator after an insertion raising the size-change `RuntimeError`;
  - a `sum_all(xs: Iterable[int])` called with a list, a range, a tuple, and a
    dict's `iter()` result through `Iterator`; a generic
    `first[T](xs: Iterable[T]) -> T` with `list[str]`;
  - `for` over an `Iterator[int]` with `break` and resume.
- `tests/programs/file_lines.wlo` with `.in`: `readline` takes the first stdin
  line, then `for line in io.stdin()` prints the rest, including a CRLF line;
  a second loop over `io.stdin()` prints nothing.
- `report.wlo` and `jsonl.wlo` run as before on sample input.
- `make test` passes.

## Implementation plan

1. `runtime/core.lua`: `__wlo_tag`, the iterator type and its helpers,
   `range_value`, and the `*_iter` helpers; `runtime/io.lua`: `file_iter`.
2. `compiler/stdlib.lua`: `types.iterator`, `io.File.iter`, and the
   dispatch-only run-time types.
3. `compiler/types.lua`: built-in `iter` signatures, protocol satisfaction by
   built-in kinds, generic flags on native signatures.
4. `compiler/check.lua`: `method_signature` for `iter`, and `range` calls.
5. `compiler/lower.lua` and `compiler/emit.lua`: `iter` method calls, the
   tuple conversion, `range` values, the extra dispatch candidates, and
   `__wlo_tag` in `Dispatch`.
6. Tests, the two examples, then check off the task in `agents/todo.md`.
