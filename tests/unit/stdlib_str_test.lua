local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local diag = require("compiler.diag")

local eq = require("tests.support").eq

local function check_error(statements)
  local source = "def main():\n    " .. statements .. "\n"
  local ok, err = pcall(function()
    local program = parser.parse(lexer.lex(source))
    bind.bind({ program })
    check.check({ program })
  end)
  if ok then
    error("expected a check error", 2)
  elseif not diag.is(err) then
    error(err, 0)
  end
  return err[1].message
end

return {
  split_argument_types = function()
    eq(check_error('"a".split(1)'), "expected str | None, received int")
    eq(check_error('"a".rsplit(",", "1")'), "expected int, received str")
    eq(check_error('"a".split(limit=1)'), "'split' has no parameter 'limit'")
  end,

  new_method_arguments = function()
    eq(check_error('"a".splitlines(1)'), "expected bool, received int")
    eq(check_error('"a".removeprefix()'), "'removeprefix' expects 1 argument, received 0")
    eq(check_error('"a".isdigit(1)'), "'isdigit' expects 0 arguments, received 1")
  end,
}
