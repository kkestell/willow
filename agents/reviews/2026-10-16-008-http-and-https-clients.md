# HTTP and HTTPS clients review

## Scope and coverage

Reviewed the staged changes for
`agents/plans/2026-10-16-007-http-and-https-clients.md`: the `http`
declarations in `compiler/bind.lua` and `compiler/check.lua`, the optional
runtime registration in `compiler/emit.lua`, `runtime/http.lua`, the test
server, the HTTP and HTTPS tests, the `api` and `fetch` examples, and the spec,
README, and todo updates. The review checked them against the plan and spec §14
`http`, using the system libcurl backend the user approved. Linux behavior was
not rechecked during the review; the plan's Verification section records it.

## Fixed

- **A `GET` with a body is sent as `POST`** (`runtime/http.lua:230`): libcurl
  switches to `POST` when `COPYPOSTFIELDS` is set, and the body was set after
  `HTTPGET`. As a result, `http.request("GET", url, body=...)` reached the
  server as `POST`, while redirects were still followed as for a `GET`. The
  fix sets the body first and sends a `GET` with a body as a custom request.
  `tests/http/client.wlo` now checks the method the server receives.
- **A failed download rename reports `nil`** (`runtime/http.lua:357`):
  `closed and os.rename(...)` dropped the rename's error message, so a download
  to a directory raised `cannot write <path>: nil`. The fix reports the
  rename's reason without the temporary file's name, as in
  `cannot write <path>: Is a directory`. `tests/http/client.wlo` covers it.
- **Concurrent downloads to one path share a temporary file**
  (`runtime/http.lua:338`): the temporary name used unseeded `math.random`, so
  every process picked the same `.part` name. Two processes downloading to the
  same path could write into one file, and either one could rename the other's
  partial body over `path`. The name now uses the process id. The plan's
  description of the name was updated to match.

## Findings

None.

## Checks run

- Ran a program against `tests/http_server.lua`. It showed that `GET` with a
  body arrived as `POST` and that a download into a directory raised
  `cannot write adir: nil`. Two LuaJIT runs printed the same first
  `math.random` value.
- Ran `tests/unit/cli_test.lua` with the new assertions, against the original
  runtime (fails) and the fixed runtime (33 passed).
- `make test`: 246 passed, 0 failed (macOS arm64).

## Verdict

The milestone matches the plan and spec. Three defects were fixed, with
regression tests, and no findings remain open.
