# Willow performance issues

This document identifies the runtime, compiler, and language costs behind the
README benchmarks. Its evidence comes from source inspection, `sample` profiles,
and timed variants. Timings were taken on an Apple M4 as the best of 3 runs with
stdout piped, the same method `benchmarks/run.py` uses. Every variant produced
its benchmark's expected output digest. Speedup is the current time divided by
the time after the change. Some experiments patch the generated IL, for example
to make a runtime function return immediately. These give an upper bound for a
fix, not the result of an implementation.

In the current README table, three benchmarks are slower than Python:

| Benchmark | Willow | Python | Willow / Python |
| --- | ---: | ---: | ---: |
| reverse-complement | 2.35 s | 0.27 s | 8.7× |
| except | 0.97 s | 0.31 s | 3.1× |
| k-nucleotide | 1.95 s | 1.59 s | 1.23× |

## Runtime

1. **Tracebacks are formatted eagerly.** Each raise and each propagating frame
   builds strings. `trace` formats the line and column with `snprintf`,
   concatenates the location onto the frames string, and searches the whole
   accumulated frames string for `"\n  in task started at "`. With `trace`
   patched to return immediately, except drops from 0.77 s to 0.017 s with
   identical output, so traceback construction is about 98% of that benchmark.
   The marker search alone is about 30% of samples, and a flag on the exception
   would remove it. See `raised` and `trace` in
   [core.wlo](../bootstrap/core/core.wlo).

2. **Output is unbuffered, with two writes per `print`.** `print_str` writes the
   text and the newline separately. Reverse-complement writes 833,000 lines of
   its 50 million bases, which makes 1.67 million writes. Output costs 0.66 s of
   its 2.33 s: a variant that builds each line but never prints it runs in
   1.67 s. Spec §14 already describes buffered standard streams and when they
   are flushed, so runtime buffering needs no specification change. See
   `write_bytes` and `print_str` in [core.wlo](../bootstrap/core/core.wlo).

3. **Runtime hot paths are compiled like ordinary Willow code.** The emitter
   compiles `core.wlo` itself. Tiny accessors such as `str_size`, `str_bytes`,
   `str_byte`, `list_len`, `list_slots`, and `list_capacity` are separate
   function calls, each followed by a pending-exception check. Internal
   arithmetic, such as capacity doubling in `list_append`, is overflow-checked.
   `core_call` inlines only `list_len`, `list_get`, and `list_set`, and only in
   user code. `tuple_get` is a call even for a constant position, which costs
   fasta about 15% of samples in `table[-1][0]` and tuple unpacking. Accessor
   bodies alone take 23% of reverse-complement samples, 13% of except, and 8% of
   k-nucleotide. See `core_call` and `inline_list` in
   [emit.wlo](../compiler/emit.wlo).

4. **String length, indexing, and slicing scan UTF-8.** `len(s)` counts
   characters, and indexing and slicing walk from the start of the string, so
   repeated indexing of a long string is quadratic. This rules out k-nucleotide's
   Python approach of slicing one long string. Fasta's `repeat_fasta` slices a
   574-byte string once per line, which costs a little. String iteration does
   not rescan. See `str_len`, `str_index`, and `str_slice` in
   [core.wlo](../bootstrap/core/core.wlo).

5. **Lists cost a header, a backing allocation, and eight bytes per element.**
   K-nucleotide builds each key with a list slice and a join, which is three
   allocations per key: about 52.5 million across its seven counting passes of
   2.5 million positions. In its profile, `str_join`, `dict_lookup`, and
   `str_hash` lead, and allocation and collection take about 15%. Nsieve's
   20.48-million-entry flag list occupies 164 MB, against 20 MB in C, and
   building it by appending takes about 30% of nsieve's samples. See
   `list_new`, `list_slice`, and `str_join` in
   [core.wlo](../bootstrap/core/core.wlo).

## Compiler and generated code

6. **Optional scalar results allocate boxes.** `dict[str, int].get(key)` returns
   a heap-boxed `int | none`. `get(key, 0)` returns a plain `int`. See
   `dict_method` and `convert` in [emit.wlo](../compiler/emit.wlo).

7. **Calls are followed by pending-exception checks.** Removing every check,
   including those inside the runtime, bounds what an analysis of non-raising
   functions could save: spectral-norm 1.04×, recursive 1.07×, n-body 1.02×, and
   methcall 1.20×. See `willow_call` and `check_pending` in
   [emit.wlo](../compiler/emit.wlo).

8. **Safety checks run inside hot loops.** List access is inlined but checks
   negative indexes and bounds, and integer arithmetic checks for overflow. In
   matrix, about 95% of samples fall inside `multiply`'s own code, which is
   dominated by these checks. Proving checks redundant is the only large lever
   for matrix. Its ceiling has not been measured. See `inline_list`, `checked`,
   and `checked_multiply` in [emit.wlo](../compiler/emit.wlo).

9. **Temporary class instances are heap objects.** Constructors call
   `object_new`. In raytracer, allocation and collection are about 33% of
   samples, and calls to small vector helpers such as `dot` account for another
   20%. Removing every temporary allocation would therefore give at most about
   1.5×. See `construct` in [emit.wlo](../compiler/emit.wlo) and
   [raytracer.wlo](../benchmarks/willow/raytracer.wlo).

## Language and standard library

10. **Bulk byte operations and compact mutable buffers are missing.** `bytes` is
    immutable, and strings have no `translate`. Python's reverse-complement
    translates and reverses the whole sequence with operations implemented in
    C, while Willow does a dictionary lookup and a list append per character.

11. **Bytes cannot be dictionary keys, and Willow has no bitwise operators.**
    Keys built from byte slices must be decoded into strings. Integer-encoded
    k-mers and packed sieve flags need `*`, `//`, and `%`, which go through
    checked arithmetic.

## Measured changes

Benchmark rewrites use only today's language. Runtime and compiler rows come
from IL patches.

| Change | Speedup |
| --- | --- |
| except: `trace` returns immediately (upper bound for issue 1) | 45× |
| reverse-complement: write output in 1,000-line batches | 1.35× |
| reverse-complement: no output at all (upper bound for issue 2) | 1.40× |
| reverse-complement: batched output, bytes, and a 256-entry complement table | 1.9× |
| fasta: write output in 1,000-line batches | 1.40× |
| fasta: inline `tuple_get` | 1.08–1.10× |
| Inline `tuple_get` and the runtime accessors (issue 3) | reverse-complement 1.09×, k-nucleotide 1.05×, fasta 1.14×, nsieve 1.07×, hash2 1.0× |
| hash2: `get(key, 0)` | 1.26× |
| k-nucleotide: `get(kmer, 0)` | 1.04× |
| k-nucleotide: byte-slice keys decoded to strings, with `get(kmer, 0)` | 1.19× |
| k-nucleotide: integer-encoded keys, with `get(kmer, 0)` | 2.04× |
| matrix: transpose `b` before multiplying | 1.05× |
| Remove all pending-exception checks (upper bound for issue 7) | 1.02–1.20× |

## Benchmark comparability

Benchmark changes should keep each benchmark's algorithm comparable across
languages. The C and Python k-nucleotide implementations both hash string
k-mers, so byte-slice keys fit that benchmark and integer encoding does not.
Reverse-complement's Python version uses bulk operations implemented in C. The
remaining gap there reflects issue 10. Recursive, methcall, binary-trees, and
except must keep recursion, protocol dispatch, tree allocation, and a million
raises, respectively.

## Fixes

Complexity is the scope of the change and the difficulty of keeping it correct,
not elapsed time.

| Fix | Complexity | Expected speedup | Basis |
| --- | --- | --- | --- |
| Structured traceback frames, formatted only when reported | Medium | except 5–15× | 45× upper bound measured. A frame record is still allocated per frame. |
| Task-start flag in place of the frames-string search | Low | except about 1.4× | 30% of samples. Subsumed by structured frames. |
| Buffered stdout at the flush points in spec §14 | Medium | reverse-complement and fasta about 1.35–1.4× | Batching measured. Must also flush before blocking reads of stdin and before writes to stderr. |
| Inline `tuple_get` and the runtime field accessors in the emitter | Low | 1.0–1.14× on runtime-heavy benchmarks | Measured by IL patch. Extends the existing `list_len` inlining. |
| `get(key, 0)` in hash2 and k-nucleotide | Low | hash2 1.26×, k-nucleotide 1.04× | Measured. Matches the Python implementations. |
| Byte-slice keys in k-nucleotide | Low | 1.19× | Measured. |
| Unboxed optional scalars | High | hash2 up to 1.26× | Same benefit as `get(key, 0)`, for code that cannot use a default. |
| ASCII fast path or cached length for strings | High | Current benchmarks about 1× | Enables slicing one long string, as Python's k-nucleotide does. |
| Compact boolean lists | High | nsieve unmeasured | Eight-fold memory reduction. Affects every generic list operation. |
| Non-raising function analysis | High | 1.02–1.20× upper bound | Measured ceiling. |
| Range analysis for loop checks | Very high | matrix unmeasured | Dominant cost in matrix. |
| Scalar replacement of temporary objects | Very high | raytracer at most about 1.5× from allocation | Profile share. Needs inlining of vector helpers to reach it. |
| String `translate` and a mutable byte buffer | Medium to high | reverse-complement beyond 1.9× after a rewrite | Byte rewrite measured at 1.9× without them. |

## Order

1. Structured traceback frames.
2. Buffered stdout. Benchmark output batching becomes unnecessary.
3. `get(key, 0)` in hash2 and k-nucleotide.
4. Inlined `tuple_get` and runtime accessors.

Profile again after these. Byte-slice keys, string fast paths, and the analyses
in issues 6 through 9 can then be judged against the costs that remain.
