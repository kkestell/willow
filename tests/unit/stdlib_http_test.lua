local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local diag = require("compiler.diag")
local runner = require("compiler.runner")
local runtime = require("compiler.runtime")

local eq = require("tests.support").eq

local function check_source(source)
  local program = parser.parse(lexer.lex(source))
  bind.bind({ program })
  check.check({ program })
end

local function check_error(source)
  local ok, err = pcall(check_source, source)
  assert(not ok and diag.is(err), "expected a check error")
  return err[1].message
end

local function capture(command)
  local shell = io.popen(command)
  local text = shell:read("*a")
  shell:close()
  return text
end

local ROOT = capture("cd " .. runner.quote(arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. " && pwd"):gsub("\n$", "")

return {
  async_requests_check_like_requests = function()
    check_source(table.concat({
      "import aio",
      "import http",
      "async def main():",
      "    h = [http.Header('A', 'b')]",
      "    r: http.Response = await http.request_async('GET', 'http://x/', headers=h, timeout=1.0)",
      "    d: http.Download = await http.download_async('http://x/', 'f', follow_redirects=False, ca_file=None)",
      "    c: Coroutine[http.Response] = http.request_async(method='POST', url='http://x/', body=bytes([1]))",
      "",
    }, "\n"))
    eq("expected float, received str", check_error(table.concat({
      "import http",
      "async def main():",
      "    await http.request_async('GET', 'http://x/', None, None, 'soon')",
      "",
    }, "\n")))
    eq("'http.download_async' has no parameter 'method'", check_error(table.concat({
      "import http",
      "async def main():",
      "    await http.download_async('http://x/', 'f', method='GET')",
      "",
    }, "\n")))
  end,

  async_helpers_bring_aio = function()
    local function has(helpers, name)
      return runtime.text(helpers):find("function __wlo_" .. name, 1, true) ~= nil
    end
    assert(has({ http_request_async = true }, "aio_sleep"))
    assert(has({ http_download_async = true }, "http_request"))
    assert(not has({ http_request = true }, "aio_sleep"))
  end,

  async_request_in_standalone_build = function()
    local dir = capture("mktemp -d"):gsub("\n$", "")
    local program = table.concat({
      "import aio",
      "import http",
      "async def main():",
      "    try:",
      "        await http.request_async('GET', 'http://127.0.0.1:1/', timeout=2.0)",
      "    except OSError as error:",
      "        print(error.message.startswith('cannot fetch http://127.0.0.1:1/: '))",
      "",
    }, "\n")
    local file = assert(io.open(dir .. "/prog.wlo", "wb"))
    file:write(program)
    file:close()
    local out = capture(string.format("cd %s && %s build prog.wlo -o prog 2>&1 && ./prog 2>&1",
      runner.quote(dir), runner.quote(ROOT .. "/willow")))
    os.execute("rm -rf " .. runner.quote(dir))
    eq("True\n", out)
  end,
}
