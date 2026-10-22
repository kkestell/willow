-- `http`'s async requests, inlined with runtime/http.lua and runtime/aio.lua
-- into programs that call them. Each is a coroutine that runs the synchronous
-- helper with aio's sleep, so the exchange advances in steps between which
-- other tasks run. Its arguments are checked once it is awaited.

function __wlo_http_request_async(method, url, headers, body, timeout, follow_redirects, ca_file, site)
  return __wlo_coroutine(function()
    __wlo_runtime.aio_checkpoint()
    return __wlo_runtime.http_request(method, url, headers, body, timeout, follow_redirects, ca_file, site,
      __wlo_runtime.aio_sleep)
  end)
end

function __wlo_http_download_async(url, path, headers, timeout, follow_redirects, ca_file, site)
  return __wlo_coroutine(function()
    __wlo_runtime.aio_checkpoint()
    return __wlo_runtime.http_download(url, path, headers, timeout, follow_redirects, ca_file, site,
      __wlo_runtime.aio_sleep)
  end)
end
