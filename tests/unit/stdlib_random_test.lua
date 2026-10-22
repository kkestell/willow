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

local function in_main(statements)
  return "import random\ndef main():\n    r = random.generator(1)\n" .. statements:gsub("[^\n]+", "    %0") .. "\n"
end

return {
  argument_types = function()
    eq("4:18: expected int, received float", check_errors(in_main("r.randint(1, 2.5)")))
    eq("4:7: cannot infer type parameter 'T' of 'choice'", check_errors(in_main("r.choice(3)")))
    eq("3:26: expected int, received str", check_errors("import random\ndef main():\n    r = random.generator('x')\n"))
  end,

  choice_returns_the_element_type = function()
    eq("4:16: expected str, received int", check_errors(in_main("x: str = r.choice([1, 2])")))
  end,
}
