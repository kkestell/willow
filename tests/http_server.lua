-- A sequential HTTP/1.1 server for the http tests. It listens on an ephemeral
-- 127.0.0.1 port, writes the port number to stdout, and serves one connection
-- at a time until it is killed.

local ffi = require("ffi")
local OSX = ffi.os == "OSX"

if OSX then
  ffi.cdef([[struct sockaddr_in { uint8_t len; uint8_t family; uint16_t port; uint32_t addr; char zero[8]; };]])
else
  ffi.cdef([[struct sockaddr_in { uint16_t family; uint16_t port; uint32_t addr; char zero[8]; };]])
end
ffi.cdef([[
int socket(int domain, int type, int protocol);
int setsockopt(int fd, int level, int name, const void *value, uint32_t length);
int bind(int fd, const struct sockaddr_in *address, uint32_t length);
int listen(int fd, int backlog);
int accept(int fd, void *address, void *length);
int getsockname(int fd, struct sockaddr_in *address, uint32_t *length);
long recv(int fd, void *buffer, size_t length, int flags);
long send(int fd, const void *buffer, size_t length, int flags);
int close(int fd);
int usleep(uint32_t microseconds);
]])
local C = ffi.C

local server = C.socket(2, 1, 0) -- AF_INET, SOCK_STREAM
C.setsockopt(server, OSX and 0xffff or 1, OSX and 4 or 2, ffi.new("int[1]", 1), 4) -- SO_REUSEADDR
local address = ffi.new("struct sockaddr_in")
address.family = 2
address.addr = 0x0100007f -- 127.0.0.1 in network order
assert(C.bind(server, address, ffi.sizeof(address)) == 0 and C.listen(server, 16) == 0)
local length = ffi.new("uint32_t[1]", ffi.sizeof(address))
C.getsockname(server, address, length)
local port = bit.rshift(bit.bswap(address.port), 16)
io.stdout:write(port, "\n")
io.stdout:flush()

local function send(client, text)
  local sent = 0
  while sent < #text do
    local count = tonumber(C.send(client, text:sub(sent + 1), #text - sent, 0))
    if count <= 0 then
      return
    end
    sent = sent + count
  end
end

local function respond(client, status, headers, body)
  local lines = { "HTTP/1.1 " .. status .. " Status", "Content-Length: " .. #body, "Connection: close" }
  for _, header in ipairs(headers) do
    lines[#lines + 1] = header
  end
  send(client, table.concat(lines, "\r\n") .. "\r\n\r\n" .. body)
end

-- Reads one request: method, path, lower-cased headers, and body.
local function read_request(client)
  local buffer, data = ffi.new("char[4096]"), ""
  while not data:find("\r\n\r\n", 1, true) do
    local count = tonumber(C.recv(client, buffer, 4096, 0))
    if count <= 0 then
      return nil
    end
    data = data .. ffi.string(buffer, count)
  end
  local head, body = data:match("^(.-)\r\n\r\n(.*)$")
  local method, path = head:match("^(%S+) (%S+)")
  local headers = {}
  for name, value in head:gmatch("\r\n([^:]+):%s*([^\r]*)") do
    headers[name:lower()] = value
  end
  local wanted = tonumber(headers["content-length"] or 0)
  while #body < wanted do
    local count = tonumber(C.recv(client, buffer, 4096, 0))
    if count <= 0 then
      break
    end
    body = body .. ffi.string(buffer, count)
  end
  return method, path, headers, body
end

local function json_string(value)
  if value == nil then
    return "null"
  end
  return '"' .. value:gsub('[%c"\\]', function(c)
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function handle(client)
  local method, path, headers, body = read_request(client)
  if not method then
    return
  end
  if path == "/json" then
    respond(client, 200, { "Content-Type: application/json" }, '{"name": "Willow", "ports": [80, 443]}')
  elseif path:match("^/status/%d+$") then
    local code = path:match("%d+")
    respond(client, code, { "X-Code: " .. code }, "status " .. code)
  elseif path:match("^/echo") then
    respond(client, 200, { "Content-Type: application/json" }, string.format(
      '{"method": %s, "path": %s, "x_test": %s, "content_type": %s, "body": %s}',
      json_string(method), json_string(path), json_string(headers["x-test"]),
      json_string(headers["content-type"]), json_string(body)))
  elseif path == "/bytes" then
    local bytes = {}
    for i = 0, 255 do
      bytes[#bytes + 1] = string.char(i)
    end
    respond(client, 200, { "Content-Type: application/octet-stream" }, table.concat(bytes))
  elseif path == "/latin1-header" then
    respond(client, 200, { "X-Name: caf\233", "X-Twice: one", "X-Twice: two" }, "ok")
  elseif path:match("^/redirect/%d+$") then
    local n = tonumber(path:match("%d+"))
    if n == 0 then
      respond(client, 200, {}, "done")
    else
      respond(client, 302, { "Location: /redirect/" .. (n - 1) }, "moved")
    end
  elseif path == "/relative" then
    respond(client, 301, { "Location: json" }, "")
  elseif path == "/loop" then
    respond(client, 302, { "Location: /loop" }, "")
  elseif path == "/post-redirect" then
    respond(client, 303, { "Location: /json" }, "see other")
  elseif path == "/to-host" then
    respond(client, 302, { "Location: http://localhost:" .. port .. "/echo" }, "")
  elseif path == "/slow" then
    send(client, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\npartial")
    C.usleep(1500000)
  elseif path == "/drop" then
    return
  else
    respond(client, 404, {}, "not found")
  end
end

while true do
  local client = C.accept(server, nil, nil)
  if client >= 0 then
    handle(client)
    C.close(client)
  end
end
