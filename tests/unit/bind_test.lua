local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local diag = require("compiler.diag")

local function eq(expected, actual)
  if expected ~= actual then
    error(string.format("expected %q, got %q", tostring(expected), tostring(actual)), 2)
  end
end

local function bind_source(source)
  local program = parser.parse(lexer.lex(source))
  bind.bind(program)
  return program
end

local function bind_error(source)
  local ok, err = pcall(bind_source, source)
  if ok then
    error("expected a binding error", 2)
  end
  if not diag.is(err) then
    error(err, 0)
  end
  return string.format("%d:%d: %s", err.span.line, err.span.col, err.message)
end

local MAIN = "def main() -> None:\n    pass\n"

return {
  signatures_collected_before_bodies = function()
    local program = bind_source(table.concat({
      "def main() -> None:",
      "    ping(3)",
      "def ping(n: int) -> None:",
      "    pong(n)",
      "def pong(n: int) -> None:",
      "    ping(n)",
    }, "\n"))
    local main, ping, pong = program.functions[1], program.functions[2], program.functions[3]
    eq(ping, main.body[1].call.target)
    eq(pong, ping.body[1].call.target)
    eq(ping, pong.body[1].call.target)
  end,

  duplicate_names_rejected = function()
    eq("3:5: duplicate function 'main'", bind_error(MAIN .. "def main() -> None:\n    pass\n"))
    eq("1:15: duplicate parameter 'a'", bind_error("def f(a: int, a: int) -> None:\n    pass\n" .. MAIN))
    eq("1:5: cannot redefine built-in function 'print'", bind_error("def print(x: int) -> None:\n    pass\n" .. MAIN))
  end,

  main_required = function()
    eq("1:1: program has no main function", bind_error("def f() -> None:\n    pass\n"))
    eq("1:5: main must take no parameters and return None", bind_error("def main(x: int) -> None:\n    pass\n"))
    eq("1:5: main must take no parameters and return None", bind_error("def main() -> int:\n    return 0\n"))
  end,

  locals_cover_the_whole_body = function()
    local program = bind_source(table.concat({
      "def f(a: int) -> None:",
      "    if a > 0:",
      "        x = 1",
      "    else:",
      "        x = 2",
      "    print(x)",
      "    a = 3",
      MAIN,
    }, "\n"))
    local f = program.functions[1]
    local x = f.body[1].body[1].symbol
    eq("x", x.name)
    eq(x, f.body[1].else_body[1].symbol)
    eq(x, f.body[2].call.args[1].symbol)
    eq(f.params[1].symbol, f.body[3].symbol)
    eq(true, f.params[1].symbol.param)
    eq(nil, x.param)
    eq(1, #f.locals)
    eq(x, f.locals[1])
  end,

  locals_shadow_functions_and_print = function()
    local program = bind_source(table.concat({
      "def g() -> int:",
      "    return 1",
      "def main() -> None:",
      "    g = 2",
      "    print = g",
      "    g = print",
    }, "\n"))
    local main = program.functions[2]
    eq(main.body[1].symbol, main.body[2].value.symbol)
    eq("print", main.body[2].symbol.name)
    eq(main.body[2].symbol, main.body[3].value.symbol)
    eq(2, #main.locals)
  end,

  cannot_call_local_variable = function()
    eq("2:5: cannot call local variable 'print'", bind_error("def main() -> None:\n    print(1)\n    print = 2\n"))
    eq("2:5: cannot call local variable 'g'", bind_error("def f(g: int) -> None:\n    g()\n" .. MAIN))
    eq("4:11: cannot call local variable 'g'",
      bind_error("def g() -> int:\n    return 1\ndef main() -> None:\n    while g() > 0:\n        g = 1\n"))
  end,

  unknown_names_rejected = function()
    eq("2:9: unknown name 'y'", bind_error("def main() -> None:\n    x = y\n"))
    eq("2:5: unknown function 'f'", bind_error("def main() -> None:\n    f()\n"))
  end,

  functions_are_not_values = function()
    eq("2:9: function 'main' cannot be used as a value", bind_error("def main() -> None:\n    x = main\n"))
    eq("2:11: function 'print' cannot be used as a value", bind_error("def main() -> None:\n    print(print)\n"))
  end,

  call_targets_recorded = function()
    local program = bind_source(table.concat({
      "def f(n: int) -> int:",
      "    return n",
      "def main() -> None:",
      "    print(1 + f(f(2)))",
    }, "\n"))
    local f = program.functions[1]
    local call = program.functions[2].body[1].call
    eq("Builtin", call.target.kind)
    eq("print", call.target.name)
    local outer = call.args[1].right
    eq(f, outer.target)
    eq(f, outer.args[1].target)
  end,
}
