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

local function in_async_main(statements)
  return "import aio\nasync def main():\n" .. statements:gsub("[^\n]+", "    %0") .. "\n"
end

return {
  semaphore_argument_and_method_types = function()
    eq("4:23: expected int, received str", check_errors(in_async_main("sem = aio.semaphore(1)\nx = aio.semaphore('a')")))
    eq("5:18: expected int, received Coroutine[None]",
      check_errors(in_async_main("sem = aio.semaphore()\nsem.release()\ny: int = sem.acquire()")))
  end,
}
