local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local diag = require("compiler.diag")

local function eq(expected, actual)
  if expected ~= actual then
    error(string.format("expected %q, got %q", tostring(expected), tostring(actual)), 2)
  end
end

local function check_source(source)
  local program = parser.parse(lexer.lex(source))
  bind.bind(program)
  check.check(program)
  return program
end

local function check_errors(source)
  local ok, err = pcall(check_source, source)
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

-- Indents statements into `main`, which starts on line 1, and appends helpers.
local function in_main(statements, helpers)
  return "def main() -> None:\n" .. statements:gsub("[^\n]+", "    %0") .. "\n" .. (helpers or "")
end

local MAIN = "def main() -> None:\n    pass\n"

return {
  expression_and_local_types = function()
    local program = check_source(in_main(table.concat({
      "a = 1 + 2",
      "b = 'x' + 'y'",
      "c = not (a < 3)",
      "d = f(a)",
      "e = print(b)",
    }, "\n"), "def f(n: int) -> str:\n    return 'n'\n"))
    local body = program.functions[1].body
    eq("int", body[1].value.type)
    eq("int", body[1].symbol.type)
    eq("str", body[2].value.type)
    eq("bool", body[3].value.type)
    eq("int", body[3].value.operand.left.type)
    eq("str", body[4].symbol.type)
    eq("None", body[5].symbol.type)
  end,

  operator_type_errors = function()
    eq("2:11: operator '+' cannot be applied to int and str", check_errors(in_main("x = 1 + 'a'")))
    eq("2:13: operator '*' cannot be applied to str and int", check_errors(in_main("x = 'a' * 2")))
    eq("2:9: operator '-' cannot be applied to str", check_errors(in_main("x = -'a'")))
    eq("2:9: operator 'not' cannot be applied to int", check_errors(in_main("x = not 1")))
    eq("2:11: operator 'and' cannot be applied to int and bool", check_errors(in_main("x = 1 and True")))
    eq("2:13: operator '<' cannot be applied to str and str", check_errors(in_main("x = 'a' < 'b'")))
    eq("2:11: operator '==' cannot be applied to int and str", check_errors(in_main("x = 1 == 'a'")))
  end,

  equality_on_all_types = function()
    local program = check_source(in_main("a = 1 == 2\nb = True != False\nc = 'x' == 'y'\nd = None == print(1)"))
    for _, statement in ipairs(program.functions[1].body) do
      eq("bool", statement.value.type)
    end
  end,

  conditions_must_be_bool = function()
    eq("2:8: expected bool, received int", check_errors(in_main("if 1:\n    pass")))
    eq("2:11: expected bool, received str", check_errors(in_main("while 's':\n    pass")))
  end,

  calls_check_arity_and_arguments = function()
    local f = "def f(a: int, b: str) -> int:\n    return a\n"
    eq("2:5: 'f' expects 2 arguments, received 1", check_errors(in_main("f(1)", f)))
    eq("2:5: 'f' expects 2 arguments, received 3", check_errors(in_main("f(1, 'a', 2)", f)))
    eq("2:7: expected int, received str", check_errors(in_main("f('a', 'b')", f)))
    eq("2:14: expected str, received int", check_errors(in_main("x: str = f(1, 'a')", f)))
    eq("2:5: 'print' expects 1 argument, received 0", check_errors(in_main("print()")))
    eq("2:5: 'print' expects 1 argument, received 2", check_errors(in_main("print(1, 2)")))
    check_source(in_main("print(1)\nprint(True)\nprint('s')\nprint(None)"))
  end,

  locals_keep_one_type = function()
    eq("3:9: expected int, received str", check_errors(in_main("x = 1\nx = 'a'")))
    eq("5:13: expected int, received str", check_errors(in_main("if True:\n    x = 1\nelse:\n    x = 'a'")))
  end,

  annotations = function()
    eq("2:14: expected int, received str", check_errors(in_main("x: int = 'a'")))
    eq("3:5: only the first assignment to 'x' can have an annotation", check_errors(in_main("x = 1\nx: int = 2")))
    eq("5:9: only the first assignment to 'x' can have an annotation",
      check_errors(in_main("if True:\n    x = 1\nelse:\n    x: int = 2")))
    eq("2:5: cannot annotate parameter 'a'", check_errors("def f(a: int) -> None:\n    a: int = 1\n" .. MAIN))
    eq("None", check_source(in_main("x: None = print(1)")).functions[1].body[1].symbol.type)
  end,

  definite_assignment = function()
    eq("2:11: variable 'x' may be used before assignment", check_errors(in_main("print(x)\nx = 1")))
    eq("4:11: variable 'x' may be used before assignment", check_errors(in_main("if True:\n    x = 1\nprint(x)")))
    eq("4:11: variable 'x' may be used before assignment", check_errors(in_main("while False:\n    x = 1\nprint(x)")))
    eq("3:15: variable 'x' may be used before assignment", check_errors(in_main("while True:\n    print(x)\n    x = 1")))
    check_source(in_main("c = 1\nif c == 1:\n    x = 1\nelif c == 2:\n    x = 2\nelse:\n    x = 3\nprint(x)"))
    check_source("def f(c: bool) -> int:\n    if c:\n        return 0\n    else:\n        x = 1\n    return x\n" .. MAIN)
  end,

  unreachable_code = function()
    eq("3:5: unreachable statement", check_errors(in_main("return\nprint(1)")))
    eq("4:9: unreachable statement", check_errors(in_main("while True:\n    break\n    print(1)")))
    eq("6:5: unreachable statement", check_errors(in_main("if True:\n    return\nelse:\n    return\nprint(1)")))
    check_source(in_main("if True:\n    return\nprint(1)"))
  end,

  missing_return = function()
    eq("1:5: function 'f' must return a value on every path", check_errors("def f() -> int:\n    pass\n" .. MAIN))
    eq("1:5: function 'f' must return a value on every path",
      check_errors("def f() -> int:\n    while True:\n        return 1\n" .. MAIN))
    eq("2:5: expected int, received None", check_errors("def f() -> int:\n    return\n" .. MAIN))
    check_source("def f(c: bool) -> int:\n    if c:\n        return 1\n    else:\n        return 2\n" .. MAIN)
  end,

  loop_transfers_outside_loop = function()
    eq("2:5: 'break' outside of a loop", check_errors(in_main("break")))
    eq("3:9: 'continue' outside of a loop", check_errors(in_main("if True:\n    continue")))
    check_source(in_main("while True:\n    if True:\n        break\n    continue"))
  end,

  independent_errors_collected = function()
    local source = table.concat({
      "def f() -> int:",
      "    return 'a'",
      "def g() -> None:",
      "    x = 1 + True",
      "    y = 'a' * 2",
      MAIN,
    }, "\n")
    eq("2:12: expected int, received str\n4:11: operator '+' cannot be applied to int and bool", check_errors(source))
  end,
}
