local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local diag = require("compiler.diag")

local eq = require("tests.support").eq

local function errors(source)
  local ok, err = pcall(function()
    local program = parser.parse(lexer.lex("import math\n\ndef main():\n    " .. source .. "\n"))
    bind.bind({ program })
    check.check({ program })
  end)
  if ok then
    error("expected a check error", 2)
  end
  if not diag.is(err) then
    error(err, 0)
  end
  return err[1].message
end

return {
  math_argument_types = function()
    eq("expected float, received int", errors("print(math.floor(2))"))
    eq("expected float, received int", errors("print(math.atan2(1.0, 2))"))
  end,

  math_constants_are_read_only_values = function()
    eq("constant 'math.pi' cannot be called", errors("print(math.pi())"))
    eq("module 'math' cannot be used as a value", errors("math.pi = 3.0"))
  end,
}
