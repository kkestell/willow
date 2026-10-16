# HTTP and HTTPS clients

## Goal

Implement `docs/spec.md` §22 on the system libcurl, the backend chosen for this
milestone: `http.request`, `http.download`, `http.header`, `http.urlencode`, and
the `Header`, `Response`, and `Download` records, with Willow's own URL rules,
header rules, redirect policy, inactivity timeout, verified TLS, and atomic
streamed downloads. Prove the backend's dependency and certificate behavior on
macOS and Linux for `run`, compiled Lua, and built executables. Deliver a JSON
API client and a binary downloader with local integration tests, and fold §22
into the baseline spec.

## Related code

- `compiler/bind.lua` — `provided` and the provided records `stat` and
  `result`.
- `compiler/check.lua` — `builtins` with `names` and `defaults`.
- `compiler/emit.lua` — `optional_runtime` and `optional_runtimes`.
- `runtime/core.lua` — `__wlo_fail`, `__wlo_list`, `__wlo_valid_utf8`,
  `__wlo_MAX_INT`, `__wlo_format_float`.
- `runtime/host.lua` — the platform constants, `__wlo_monotonic`, `__wlo_join`,
  `__wlo_dirname`, and `__wlo_check_path`, which `http.lua` cannot reach from its
  own block.
- `tests/unit/cli_test.lua` — `sh`, `willow`, `in_temp_dir`.

## Decisions

- **Backend and deployment.** `runtime/http.lua` loads libcurl through
  `ffi.load` on the first request (`libcurl.4.dylib` on macOS, `libcurl.so.4`
  on Linux). macOS includes it; on Linux, programs that use `http` need
  `libcurl4` and `ca-certificates`. Failure to load raises `OSError`
  `cannot load libcurl: <reason>`. Programs that do not import `http` keep their
  current dependencies. README states the requirement.
- **Placement.** `runtime/http.lua` is a new optional runtime with its own
  `ffi` declarations under `__wlo_curl_` names. It needs a monotonic clock and
  a sibling path, which it computes itself (`clock_gettime` through its own
  declaration and plain string handling) rather than reaching into
  `runtime/host.lua`'s block.
- **Declarations.** `M.modules.http` provides `request`, `download`, `header`,
  and `urlencode` (helpers `http_request`, `http_download`, `http_header`,
  `http_urlencode`) and the records `Header(name: str, value: str)`,
  `Response(status: int, headers: list[Header], body: bytes, url: str)`, and
  `Download(status: int, headers: list[Header], url: str, bytes_written: int)`
  with type names `http.Header`, `http.Response`, and `http.Download`.
- **URLs.** `__wlo_http_url(text)` splits scheme, authority, path, and query,
  drops the fragment, and rejects (`ValueError` `invalid URL '<url>'`) other
  schemes, a missing or non-ASCII host, a non-numeric or out-of-range port, and
  user information (`URL user information is not allowed`). It percent-encodes
  bytes outside the RFC 3986 unreserved, sub-delimiter, `:`, `@`, `/`, `?`, and
  `%` sets, and a `%` not followed by two hex digits, and adds `/` for an empty
  path. Redirect targets resolve with curl's `CURLINFO_REDIRECT_URL`, then pass
  through the same function.
- **Headers.** Names must be tokens and values printable ASCII or tab
  (`ValueError` `invalid header name '<name>'` /
  `invalid header value for '<name>'`); `Host`, `Content-Length`, and
  `Transfer-Encoding` raise `ValueError` `header '<name>' is managed by the
  transport`. Methods must be tokens (`invalid method '<method>'`). Received
  header lines are collected for each response (reset at each status line);
  bytes above 127 become U+0080–U+00FF in UTF-8.
- **Requests.** Each exchange uses a fresh easy handle with: `CURLOPT_URL`;
  `CURLOPT_CUSTOMREQUEST` set to the method, except `HTTPGET` for a `GET`
  without a body and `NOBODY` for `HEAD`; `POSTFIELDS` and
  `POSTFIELDSIZE_LARGE` for a body, set before the method options;
  `HTTPHEADER`; `PROTOCOLS_STR` `http,https`; `PROXY` `""` and `NOPROXY` `*`
  so proxy variables are ignored; `FOLLOWLOCATION` off; `SSL_VERIFYPEER` and
  `SSL_VERIFYHOST` on; `CAINFO` when `ca_file` is given; `CONNECTTIMEOUT_MS`;
  `ERRORBUFFER`; and write, header, and `XFERINFOFUNCTION` callbacks made with
  `ffi.cast` and freed after the transfer. Errors raised in callbacks are kept
  and raised after `curl_easy_perform` returns. The function that calls
  `curl_easy_perform` is excluded from JIT compilation, since LuaJIT cannot call
  back into Lua from a compiled C call.
- **Errors and timeouts.** The progress callback records the monotonic time of
  the last change in transferred bytes and aborts when it is older than
  `timeout`; an abort or `CURLE_OPERATION_TIMEDOUT` raises `TimeoutError`
  `request timed out after <timeout> seconds`. Other curl failures raise
  `OSError` `cannot fetch <url>: <error buffer or curl_easy_strerror>`. A
  timeout must be finite and positive.
- **Redirects.** With `follow_redirects` and a `GET` or `HEAD`, statuses 301,
  302, 303, 307, and 308 with a redirect URL are followed up to ten hops; the
  eleventh raises `OSError` `too many redirects`, an `https` to `http` hop
  raises `OSError` `refusing to follow a redirect from https to http`, and a
  missing or invalid target raises `OSError`. When scheme, host, or effective
  port changes, the caller's headers are dropped for the remaining hops.
  `Response.url` and the headers describe the final exchange.
- **Downloads.** `download` opens a temporary sibling
  `<dir>/.<name>.<pid>.part` for writing, and the write callback writes to it
  only while the current response is a 2xx; other bodies are discarded. On a
  2xx final response it flushes, closes, and renames the file over `path` and
  reports its size; otherwise, or on any failure, it removes the temporary file
  and leaves `path` alone. A non-2xx final response returns `bytes_written` 0.
- **Helpers.** `header` compares names case-insensitively and returns the first
  value. `urlencode` encodes each key and value as UTF-8 with
  `A–Z a–z 0–9 - . _ ~` kept, spaces as `+`, and the rest as `%XX`, joined with
  `&` in insertion order.

## Test plan

- `tests/programs/http_values.wlo` and `.out` (no network): `urlencode` with
  spaces, `&`, `=`, non-ASCII text, and empty values; `header` case
  insensitivity, first match, and `None`; invalid URLs (`ftp:`, no host,
  user information, bad port, relative), invalid methods and headers, managed
  headers, and invalid timeouts, each raising `ValueError` before any network
  access.
- `tests/http_server.lua`: a sequential HTTP/1.1 test server on an ephemeral
  `127.0.0.1` port written with LuaJIT `ffi` sockets, printing its port. Routes:
  `/json`, `/status/<code>`, `/echo` (method, selected request headers, and
  body as JSON), `/bytes` (all 256 byte values), `/latin1-header`,
  `/redirect/<n>` chains, `/to-host` (an absolute redirect to `localhost` on the
  same port), `/loop`, `/post-redirect`, `/slow` (stalls past the timeout), and
  `/drop` (closes without a response).
- `tests/unit/cli_test.lua` `http_client`: start the server, run a Willow
  program that exercises: status codes including 404 and 500, JSON round trip
  through `/echo` with headers and a body, binary bodies, latin-1 headers,
  redirects (count, final URL, `POST` not followed, `follow_redirects=False`,
  ten-hop limit, header dropping on origin change), `HEAD`, inactivity
  `TimeoutError`, `/drop` and a closed port raising `OSError`; and downloads
  (success replaces an existing file, a 404 and a dropped connection leave it
  intact with no `.part` file left).
- `tests/unit/cli_test.lua` `https_client`, when `openssl` is available: a
  self-signed certificate for `localhost` served by `openssl s_server -WWW`;
  a request with `ca_file` succeeds, one without it fails with `OSError`, and one
  to `127.0.0.1` (a name the certificate lacks) fails.
- `api_example` and `fetch_example` against the test server.
- One-off, recorded under `## Verification`: an HTTPS request to a public site
  with platform certificates through `run`, compiled Lua, and a built executable
  on macOS and in a Linux container with `libcurl4` and `ca-certificates`, and
  the `cannot load libcurl` error in a container without them.

## Implementation plan

1. `compiler/bind.lua` and `compiler/check.lua`: the `http` declarations.
2. `runtime/http.lua`; add it to `optional_runtimes`.
3. `tests/http_server.lua` and the tests above.
4. `examples/api.wlo`: `api <url>` fetches JSON, prints selected fields, then
   posts a JSON object and prints the echoed result. `examples/fetch.wlo`:
   `fetch <url> <path>` downloads with a timeout and reports the status and
   bytes written.
5. Verify on macOS and Linux and record the results.
6. Fold §22 into `docs/spec.md` (§14 gains `### http`, including the resolver
   limitation), add the libcurl requirement to `README.md`, and check off the
   milestone in `agents/todo.md`.

## Documentation updates

- `docs/spec.md`: `### http` in §14; the §22 heading keeps one sentence saying
  where its rules live; the top pointer and milestones introduction say
  sections 23–24 are unimplemented.
- `README.md`: the libcurl requirement for programs that use `http`.
- `agents/todo.md`: check off §22.

## Verification

A program requesting `https://example.com/` with the platform certificates
printed `200 https://example.com/ True` through `willow run`, through compiled Lua
run by the bundled LuaJIT, and through a built executable run from `/`:

- macOS 26 arm64, with the system libcurl 8.7.1 (SecureTransport).
- Debian bookworm arm64 after installing `libcurl4` and `ca-certificates`, where
  `make test` (including the local HTTPS test) also passed.

In the same container before installing them, `willow run` and the built
executable both reported
`OSError: cannot load libcurl: libcurl.so.4: cannot open shared object file: No such file or directory`.
