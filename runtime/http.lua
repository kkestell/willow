-- HTTP and HTTPS through the system libcurl, inlined after runtime/core.lua
-- into programs that use the http module. libcurl is loaded on first use. The
-- helpers are the functions declared without `local`.

__wlo_ffi.cdef([[
typedef void __wlo_curl_t;
typedef struct __wlo_curl_slist __wlo_curl_slist_t;
int curl_global_init(long flags);
__wlo_curl_t *curl_easy_init(void);
void curl_easy_cleanup(__wlo_curl_t *handle);
int curl_easy_setopt(__wlo_curl_t *handle, int option, ...);
int curl_easy_perform(__wlo_curl_t *handle);
__wlo_curl_t *curl_multi_init(void);
int curl_multi_add_handle(__wlo_curl_t *multi, __wlo_curl_t *handle);
int curl_multi_remove_handle(__wlo_curl_t *multi, __wlo_curl_t *handle);
int curl_multi_perform(__wlo_curl_t *multi, int *running);
int curl_multi_timeout(__wlo_curl_t *multi, long *milliseconds);
int curl_multi_cleanup(__wlo_curl_t *multi);
typedef struct { int msg; __wlo_curl_t *handle; union { void *other; int result; } data; } __wlo_curl_msg_t;
__wlo_curl_msg_t *curl_multi_info_read(__wlo_curl_t *multi, int *queued);
int curl_easy_getinfo(__wlo_curl_t *handle, int info, ...);
const char *curl_easy_strerror(int code);
__wlo_curl_slist_t *curl_slist_append(__wlo_curl_slist_t *list, const char *text);
void curl_slist_free_all(__wlo_curl_slist_t *list);
int __wlo_curl_getpid(void) __asm__("getpid");
]])

local __wlo_CURL_NAME = __wlo_ffi.os == "OSX" and "libcurl.4.dylib" or "libcurl.so.4"
local __wlo_curl_library
local __wlo_download_id = 0

local __wlo_OPT = {
  url = 10002, errorbuffer = 10010, postfieldsize_large = 30120, copypostfields = 10165,
  httpheader = 10023, customrequest = 10036, nobody = 44, httpget = 80, followlocation = 52,
  noprogress = 43, xferinfofunction = 20219, writefunction = 20011, headerfunction = 20079,
  connecttimeout_ms = 156, ssl_verifypeer = 64, ssl_verifyhost = 81, cainfo = 10065,
  proxy = 10004, noproxy = 10177, protocols_str = 10318, nosignal = 99,
}
local __wlo_INFO_RESPONSE_CODE, __wlo_INFO_REDIRECT_URL = 0x200002, 0x10001F
local __wlo_CURLE_TIMEDOUT, __wlo_CURLE_ABORTED = 28, 42
local __wlo_REDIRECTS = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }
local __wlo_MANAGED = { host = true, ["content-length"] = true, ["transfer-encoding"] = true }
local __wlo_TOKEN = "^[!#$%%&'*+%-.^_`|~%w]+$"

local function __wlo_curl(site)
  if not __wlo_curl_library then
    local ok, library = pcall(__wlo_ffi.load, __wlo_CURL_NAME)
    if not ok then
      __wlo_fail("OSError", "cannot load libcurl: " .. tostring(library), site)
    end
    library.curl_global_init(3)
    __wlo_curl_library = library
  end
  return __wlo_curl_library
end

local function __wlo_percent(byte)
  return string.format("%%%02X", byte:byte())
end

-- Splits and normalizes an absolute http or https URL: the fragment is
-- dropped, the host lowered, and bytes outside the URL character set and
-- stray `%` signs are percent-encoded.
local function __wlo_http_url(text, site)
  local function invalid()
    __wlo_fail("ValueError", "invalid URL '" .. text .. "'", site)
  end
  local scheme, rest = text:gsub("#.*$", ""):match("^(%a[%w+.-]*)://(.*)$")
  scheme = scheme and scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then
    invalid()
  end
  local authority, path = rest:match("^([^/?]*)(.*)$")
  if authority:find("@", 1, true) then
    __wlo_fail("ValueError", "URL user information is not allowed", site)
  end
  local host, port = authority:match("^(%[[%x:.]+%])(.*)$")
  if not host then
    host, port = authority:match("^([^:]*)(.*)$")
    if not host:match("^[%w.-]+$") then
      invalid()
    end
  end
  if port ~= "" then
    port = port:match("^:(%d+)$")
    if not port or tonumber(port) < 1 or tonumber(port) > 65535 then
      invalid()
    end
  end
  host = host:lower()
  if path == "" or path:sub(1, 1) == "?" then
    path = "/" .. path
  end
  local encoded, i = {}, 1
  while i <= #path do
    local char = path:sub(i, i)
    if char == "%" and path:sub(i + 1, i + 2):match("^%x%x$") then
      encoded[#encoded + 1] = path:sub(i, i + 2)
      i = i + 3
    else
      encoded[#encoded + 1] = char:match("[%w%-._~!$&'()*+,;=:@/?]") or __wlo_percent(char)
      i = i + 1
    end
  end
  path = table.concat(encoded)
  local effective = tonumber(port ~= "" and port or nil) or (scheme == "https" and 443 or 80)
  return {
    text = scheme .. "://" .. host .. (port ~= "" and ":" .. port or "") .. path,
    scheme = scheme,
    origin = scheme .. "://" .. host .. ":" .. effective,
  }
end

local function __wlo_check_headers(headers, site)
  local lines = {}
  for i = 1, headers and headers.n or 0 do
    local name, value = headers[i].name, headers[i].value
    if not name:match(__wlo_TOKEN) then
      __wlo_fail("ValueError", "invalid header name '" .. name .. "'", site)
    elseif __wlo_MANAGED[name:lower()] then
      __wlo_fail("ValueError", "header '" .. name .. "' is managed by the transport", site)
    elseif value:find("[^\t\32-\126]") then
      __wlo_fail("ValueError", "invalid header value for '" .. name .. "'", site)
    end
    lines[#lines + 1] = name .. ": " .. value
  end
  return lines
end

-- Received header bytes above 127 stand for U+0080 through U+00FF.
local function __wlo_latin1(text)
  return (text:gsub("[\128-\255]", function(char)
    return __wlo_chr(char:byte())
  end))
end

local function __wlo_header_list(pairs_list)
  local items = {}
  for i, pair in ipairs(pairs_list) do
    items[i] = { "http.Header", name = pair[1], value = pair[2] }
  end
  return __wlo_list(items, #items)
end

-- Runs `curl_easy_perform` outside compiled code, which cannot be reentered
-- by the callbacks.
local function __wlo_curl_perform(curl, handle)
  return curl.curl_easy_perform(handle)
end
jit.off(__wlo_curl_perform)

local function __wlo_curl_multi_perform(curl, multi, running)
  return curl.curl_multi_perform(multi, running)
end
jit.off(__wlo_curl_multi_perform)

-- Advances the transfer on `handle` with libcurl's multi interface, calling
-- `sleep(seconds)` between steps so other tasks run, and returns its result
-- code. The steps are at most 10 ms apart, sooner when libcurl asks. A true
-- `expired()` aborts the transfer. libcurl's own resolver may still block a
-- step: only a threaded or c-ares build looks up names in the background.
local function __wlo_curl_drive(curl, handle, expired, sleep)
  local ffi = __wlo_ffi
  local multi = curl.curl_multi_init()
  local running, millis, queued = ffi.new("int[1]", 1), ffi.new("long[1]"), ffi.new("int[1]")
  curl.curl_multi_add_handle(multi, handle)
  local ok, code = pcall(function()
    while true do
      __wlo_curl_multi_perform(curl, multi, running)
      if running[0] == 0 then
        local message = curl.curl_multi_info_read(multi, queued)
        return message ~= nil and message.data.result or __wlo_CURLE_ABORTED
      elseif expired() then
        return __wlo_CURLE_ABORTED
      end
      curl.curl_multi_timeout(multi, millis)
      sleep(millis[0] < 0 and 0.01 or math.min(tonumber(millis[0]), 10) / 1000)
    end
  end)
  curl.curl_multi_remove_handle(multi, handle)
  curl.curl_multi_cleanup(multi)
  if not ok then
    error(code, 0)
  end
  return code
end

-- One exchange. `body_sink(chunk, status)` receives the response body and
-- returns an error message to stop the transfer. Returns the status, the response
-- headers as { name, value } pairs, and the redirect target if any. A `sleep`
-- function makes the exchange wait by calling it instead of blocking.
local function __wlo_http_exchange(method, url, header_lines, body, timeout, ca_file, body_sink, site, sleep)
  local curl = __wlo_curl(site)
  local ffi = __wlo_ffi
  local handle = curl.curl_easy_init()
  local function set(option, value)
    if type(value) == "number" then
      value = ffi.new("long", value)
    end
    curl.curl_easy_setopt(handle, __wlo_OPT[option], value)
  end
  local errors = ffi.new("char[256]")
  local response_headers, failure = {}, nil
  local last_bytes, last_time = -1, __wlo_clock(__wlo_CLOCK_MONOTONIC)
  local timed_out = false

  local write = ffi.cast("size_t (*)(char *, size_t, size_t, void *)", function(data, size, count)
    local length = tonumber(size * count)
    last_time = __wlo_clock(__wlo_CLOCK_MONOTONIC)
    local status = ffi.new("long[1]")
    curl.curl_easy_getinfo(handle, __wlo_INFO_RESPONSE_CODE, status)
    failure = failure or body_sink(ffi.string(data, length), tonumber(status[0]))
    return failure and 0 or length
  end)
  local read_header = ffi.cast("size_t (*)(char *, size_t, size_t, void *)", function(data, size, count)
    local length = tonumber(size * count)
    last_time = __wlo_clock(__wlo_CLOCK_MONOTONIC)
    local line = ffi.string(data, length):gsub("\r?\n$", "")
    if line:match("^HTTP/") then
      response_headers = {}
    elseif line:match("^[ \t]") and #response_headers > 0 then
      local last = response_headers[#response_headers]
      last[2] = last[2] .. " " .. __wlo_latin1(line:match("^%s*(.-)%s*$"))
    else
      local name, value = line:match("^([^:]+):%s*(.-)%s*$")
      if name then
        response_headers[#response_headers + 1] = { __wlo_latin1(name), __wlo_latin1(value) }
      end
    end
    return length
  end)
  local progress = ffi.cast("int (*)(void *, int64_t, int64_t, int64_t, int64_t)", function(_, _, now_down, _, now_up)
    local bytes = tonumber(now_down + now_up)
    local now = __wlo_clock(__wlo_CLOCK_MONOTONIC)
    if bytes ~= last_bytes then
      last_bytes, last_time = bytes, now
    elseif now - last_time > timeout then
      timed_out = true
      return 1
    end
    return 0
  end)

  local list = nil
  for _, line in ipairs(header_lines) do
    list = curl.curl_slist_append(list, line)
  end
  set("url", url)
  set("errorbuffer", errors)
  set("protocols_str", "http,https")
  set("proxy", "")
  set("noproxy", "*")
  set("nosignal", 1)
  set("followlocation", 0)
  set("ssl_verifypeer", 1)
  set("ssl_verifyhost", 2)
  set("connecttimeout_ms", math.ceil(timeout * 1000))
  if ca_file then
    set("cainfo", ca_file)
  end
  -- A body switches curl to POST, so the method options come after it and a
  -- GET with a body is sent as a custom request.
  if body then
    curl.curl_easy_setopt(handle, __wlo_OPT.postfieldsize_large, ffi.new("int64_t", #body.__wlo_octets))
    set("copypostfields", body.__wlo_octets)
  end
  if method == "HEAD" then
    set("nobody", 1)
  elseif method == "GET" and not body then
    set("httpget", 1)
  else
    set("customrequest", method)
  end
  if list ~= nil then
    set("httpheader", list)
  end
  set("writefunction", write)
  set("headerfunction", read_header)
  set("xferinfofunction", progress)
  set("noprogress", 0)

  local function release()
    curl.curl_easy_cleanup(handle)
    curl.curl_slist_free_all(list)
    write:free()
    read_header:free()
    progress:free()
  end
  local code
  if sleep then
    local ok, result = pcall(__wlo_curl_drive, curl, handle, function()
      timed_out = __wlo_clock(__wlo_CLOCK_MONOTONIC) - last_time > timeout
      return timed_out
    end, sleep)
    if not ok then
      release()
      error(result, 0)
    end
    code = result
  else
    code = __wlo_curl_perform(curl, handle)
  end
  local status, target = ffi.new("long[1]"), ffi.new("char *[1]")
  curl.curl_easy_getinfo(handle, __wlo_INFO_RESPONSE_CODE, status)
  curl.curl_easy_getinfo(handle, __wlo_INFO_REDIRECT_URL, target)
  local redirect = target[0] ~= nil and ffi.string(target[0]) or nil
  local message = ffi.string(errors)
  if message == "" then
    message = ffi.string(curl.curl_easy_strerror(code))
  end
  release()

  if failure then
    __wlo_fail("OSError", failure, site)
  elseif timed_out or code == __wlo_CURLE_TIMEDOUT then
    __wlo_fail("TimeoutError", "request timed out after " .. __wlo_format_float(timeout) .. " seconds", site)
  elseif code ~= 0 then
    __wlo_fail("OSError", "cannot fetch " .. url .. ": " .. message, site)
  end
  return tonumber(status[0]), response_headers, redirect
end

-- Follows redirects as the spec allows and returns the final status,
-- headers, and URL. `body_sink(chunk, status, hop)` sees every response body,
-- numbered by hop.
local function __wlo_http_fetch(method, url, headers, body, timeout, follow, ca_file, body_sink, site, sleep)
  if not method:match(__wlo_TOKEN) then
    __wlo_fail("ValueError", "invalid method '" .. method .. "'", site)
  end
  local current = __wlo_http_url(url, site)
  local lines = __wlo_check_headers(headers, site)
  __wlo_check_timeout(timeout, site)
  local hops = 0
  while true do
    local hop = hops
    local status, response_headers, redirect = __wlo_http_exchange(method, current.text, lines, body, timeout,
      ca_file, function(chunk, status)
        return body_sink(chunk, status, hop)
      end, site, sleep)
    if not (follow and (method == "GET" or method == "HEAD") and __wlo_REDIRECTS[status] and redirect) then
      return status, response_headers, current.text
    end
    hops = hops + 1
    if hops > 10 then
      __wlo_fail("OSError", "too many redirects", site)
    end
    local ok, target = pcall(__wlo_http_url, redirect, site)
    if not ok then
      __wlo_fail("OSError", "invalid redirect target '" .. redirect .. "'", site)
    elseif current.scheme == "https" and target.scheme == "http" then
      __wlo_fail("OSError", "refusing to follow a redirect from https to http", site)
    end
    if target.origin ~= current.origin then
      lines = {}
    end
    current = target
  end
end

-- The request and download helpers take the `sleep` of an async exchange.
function __wlo_http_request(method, url, headers, body, timeout, follow_redirects, ca_file, site, sleep)
  -- Only the final exchange's body is kept.
  local parts, parts_hop = {}, 0
  local status, response_headers, final = __wlo_http_fetch(method, url, headers, body, timeout, follow_redirects,
    ca_file, function(chunk, _, hop)
      if hop ~= parts_hop then
        parts, parts_hop = {}, hop
      end
      parts[#parts + 1] = chunk
    end, site, sleep)
  return {
    "http.Response",
    status = status,
    headers = __wlo_header_list(response_headers),
    body = { __wlo_octets = table.concat(parts) },
    url = final,
  }
end

function __wlo_http_download(url, path, headers, timeout, follow_redirects, ca_file, site, sleep)
  __wlo_check_path(path, site)
  local directory, name = path:match("^(.-)([^/]*)$")
  -- The counter distinguishes concurrent tasks within the same process.
  __wlo_download_id = __wlo_download_id + 1
  local temp = string.format("%s.%s.%d.%d.part", directory, name, __wlo_ffi.C.__wlo_curl_getpid(), __wlo_download_id)
  local file, open_error = io.open(temp, "wb")
  if not file then
    __wlo_fail("OSError", "cannot write " .. path .. ": " .. __wlo_open_reason(open_error, temp), site)
  end
  local written = 0
  local ok, status, response_headers, final = pcall(__wlo_http_fetch, "GET", url, headers, nil, timeout,
    follow_redirects, ca_file, function(chunk, chunk_status)
      if chunk_status < 200 or chunk_status > 299 then
        return nil
      end
      local wrote, err = file:write(chunk)
      if not wrote then
        return "cannot write " .. path .. ": " .. tostring(err)
      end
      written = written + #chunk
    end, site, sleep)
  local closed, close_error = file:close()
  if ok and status >= 200 and status <= 299 then
    local reason = close_error
    if closed then
      local renamed, rename_error = os.rename(temp, path)
      reason = not renamed and __wlo_open_reason(rename_error, temp)
    end
    if reason then
      os.remove(temp)
      __wlo_fail("OSError", "cannot write " .. path .. ": " .. reason, site)
    end
    if written > __wlo_MAX_INT then
      __wlo_fail("OverflowError", "download size out of range", site)
    end
  else
    os.remove(temp)
    written = 0
  end
  if not ok then
    error(status, 0)
  end
  return {
    "http.Download",
    status = status,
    headers = __wlo_header_list(response_headers),
    url = final,
    bytes_written = written,
  }
end

function __wlo_http_header(headers, name, site)
  local wanted = name:lower()
  for i = 1, headers.n do
    if headers[i].name:lower() == wanted then
      return headers[i].value
    end
  end
  return nil
end

function __wlo_http_urlencode(values, site)
  local function encode(text)
    return (text:gsub("[^%w%-._~ ]", __wlo_percent):gsub(" ", "+"))
  end
  local pairs_text = {}
  for _, key in ipairs(values.keys) do
    pairs_text[#pairs_text + 1] = encode(key) .. "=" .. encode(values.values[key])
  end
  return table.concat(pairs_text, "&")
end
