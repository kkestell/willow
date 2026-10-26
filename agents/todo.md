# TODO

---

- Add integer bitwise operators: `&`, `|`, `^`, `~`, `<<`, and `>>`.
- Add regular expressions and fill common text API gaps: `count`, `rfind`,
  `partition`, `int(text, base)`, and zero-padded and hexadecimal formatting.
- Expose missing OS operations: signal handling, `chmod`, `symlink`, `readlink`,
  local UTC offset, file seeking, `chdir`, and `getpid`.
- Add SHA-256 hashing for download verification, cache keys, and content
  addressing.
- Decide whether to allow user `extern` declarations so external libraries can
  provide C-backed capabilities without expanding the standard library.
- amd64 has no test machine. Creating a coroutine on amd64 fails with a clear
  error. On Intel macOS, `fs.stat` and `fs.listdir` use the arm64 `stat` and
  `dirent` layouts and unsuffixed symbols, where the x86_64 ABI needs the
  `$INODE64` entry points.
- `willow run` rejects a program argument that is not valid UTF-8 in its own
  `sys.args()`; a built executable receives it and raises `ValueError` as
  specified.
- A failed write to stdout or stderr reports `cannot write output: <reason>`
  without the call's source location.
- `subprocess`'s async methods check child status every 10 ms rather than
  waiting on pipe readiness.
- The checker reports the first error in a program.
