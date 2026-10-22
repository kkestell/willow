local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local diag = require("compiler.diag")

local eq = require("tests.support").eq

local function check_errors(source)
  local ok, err = pcall(function()
    local program = parser.parse(lexer.lex(source))
    bind.bind({ program })
    check.check({ program })
  end)
  if ok then
    error("expected a check error", 2)
  end
  if not diag.is(err) then
    error(err, 0)
  end
  local lines = {}
  for i, d in ipairs(err) do
    lines[i] = string.format("%d:%d: %s", d.span.line, d.span.col, d.message)
  end
  return table.concat(lines, "\n")
end

local function in_main(body)
  return "def main():\n    data = bytes([1])\n    " .. body:gsub("\n", "\n    ") .. "\n"
end

return {
  method_errors = function()
    eq("3:19: expected bytes, received str", check_errors(in_main("x = data.find('a')")))
    eq("3:26: expected int, received str", check_errors(in_main("x = data.split(data, 'a')")))
    eq("3:25: 'startswith' has no parameter 'sub'", check_errors(in_main("x = data.startswith(sub=data)")))
    eq("3:14: 'hex' expects 0 arguments, received 1", check_errors(in_main("x = data.hex(1)")))
    eq("3:19: expected int, received str", check_errors(in_main("x: int = data.hex()")))
  end,
  fromhex_errors = function()
    eq("2:23: expected str, received int", check_errors("def main():\n    x = bytes.fromhex(1)"))
    eq("2:15: type 'bytes' has no static method 'frombytes'", check_errors("def main():\n    x = bytes.frombytes('')"))
  end,
}
