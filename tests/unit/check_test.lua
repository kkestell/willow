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

  float_types = function()
    local program = check_source(in_main(table.concat({
      "a = 1.5 * -2.0 + 0.5 - 1.0",
      "b = 7 / 2",
      "c = 7 // 2 + 7 % 2",
      "d = 7.0 // 2.0 + 7.0 % 2.0",
      "e = a < b and a != b",
      "f = int(a)",
      "g = float(f)",
    }, "\n")))
    local types = {}
    for i, statement in ipairs(program.functions[1].body) do
      types[i] = statement.value.type
    end
    eq("float float int float bool int float", table.concat(types, " "))
  end,

  float_type_errors = function()
    eq("2:11: operator '+' cannot be applied to int and float", check_errors(in_main("x = 1 + 1.5")))
    eq("2:11: operator '==' cannot be applied to int and float", check_errors(in_main("x = 1 == 1.0")))
    eq("2:11: operator '<' cannot be applied to int and float", check_errors(in_main("x = 1 < 1.5")))
    eq("2:13: operator '/' cannot be applied to str and str", check_errors(in_main("x = 'a' / 'b'")))
    eq("2:13: expected float, received int", check_errors(in_main("x = int(1)")))
    eq("2:15: expected int, received float", check_errors(in_main("x = float(1.5)")))
    eq("2:9: 'float' expects 1 argument, received 0", check_errors(in_main("x = float()")))
  end,

  optional_assignability = function()
    local g = "def g(a: int | None) -> int | None:\n    if a is None:\n        return\n    return 1\n"
    check_source(in_main("x = g(1)\ny = g(None)\nz: int | None = g(x)", g))
    eq("2:12: expected int, received int | None",
      check_errors("def h(a: int | None) -> int:\n    return a\n" .. MAIN))
    eq("2:7: expected int | None, received str", check_errors(in_main("g('a')", g)))
    eq("2:23: expected float | None, received int | None",
      check_errors(in_main("x: float | None = g(1)", g)))
  end,

  optional_reassignment = function()
    check_source(in_main("x: int | None = None\nx = 3\nx = None"))
    eq("3:9: expected None, received int", check_errors(in_main("x = None\nx = 3")))
    eq("3:9: expected int, received None", check_errors(in_main("x = 1\nx = None")))
  end,

  optional_operations = function()
    local function errors(statements)
      return check_errors(in_main("x: int | None = None\nif x is None:\n    pass\n" .. statements))
    end
    eq("5:11: operator '+' cannot be applied to int | None and int", errors("y = x + 1"))
    eq("5:11: operator '<' cannot be applied to int | None and int", errors("y = x < 1"))
    eq("5:8: expected bool, received int | None", errors("if x:\n    pass"))
    eq("5:11: operator '==' cannot be applied to int | None and str", errors("y = x == 'a'"))
    eq("3:11: operator 'is' cannot be applied to int", check_errors(in_main("x = 1\ny = x is None")))
    eq("2:14: operator 'is not' cannot be applied to None", check_errors(in_main("y = None is not None")))
    check_source(in_main("x: int | None = None\nif x is None:\n    pass\na = x == 1\nb = None != x\nprint(x)"))
  end,

  narrowing = function()
    -- `f` starts on line 1 with optional parameters x and y.
    local function f(statements)
      return "def f(x: int | None, y: int | None) -> None:\n" .. statements:gsub("[^\n]+", "    %0") .. "\n" .. MAIN
    end
    local valid = {
      "if x is None:\n    return\nprint(x + 1)",
      "if x is None:\n    pass\nelif y is None:\n    print(x + 1)\nelse:\n    print(x + y)",
      "if x is not None and x > 0:\n    print(x + 1)",
      "if x is None or y is None:\n    return\nprint(x + y)",
      "ok = x is None or x > 0",
      "if not x is None:\n    print(x + 1)",
      "if not (x is not None):\n    return\nprint(x + 1)",
      "if x is None:\n    x = 1\nprint(x + 1)",
      "while x is not None:\n    print(x + 1)\n    x = None",
      "if x is None:\n    return\nwhile False:\n    print(x + 1)\nprint(x + 1)",
    }
    for _, statements in ipairs(valid) do
      check_source(f(statements))
    end
    local unnarrowed = "operator '+' cannot be applied to int | None and int"
    eq("4:13: " .. unnarrowed, check_errors(f("if x is not None:\n    pass\nprint(x + 1)")))
    eq("5:13: " .. unnarrowed, check_errors(f("if x is None:\n    return\nx = y\nprint(x + 1)")))
    eq("2:27: operator '>' cannot be applied to int | None and int",
      check_errors(f("if x is not None or x > 0:\n    pass")))
    eq("5:17: " .. unnarrowed, check_errors(f("if x is None:\n    return\nwhile True:\n    print(x + 1)\n    x = None")))
    eq("6:13: " .. unnarrowed, check_errors(f("if x is None:\n    return\nwhile False:\n    x = None\nprint(x + 1)")))
  end,

  display_types = function()
    local helpers = "def f(x: list[int]) -> None:\n    pass\ndef g() -> dict[str, int]:\n    return {}\n"
    check_source(in_main(table.concat({
      "a: list[int] = []",
      "b: dict[str, int] = {}",
      "c: list[int | None] = [1, None]",
      "d: list[list[int]] = [[], [1]]",
      "e = [[1], []]",
      "h: list[int] | None = []",
      "f([])",
      "d.append([])",
    }, "\n"), helpers))
    local program = check_source(in_main("x = [1, 2]\ny = {'a': [1.5]}"))
    eq("list[int]", program.functions[1].body[1].symbol.type)
    eq("dict[str, list[float]]", program.functions[1].body[2].symbol.type)
    eq("2:13: expected int, received str", check_errors(in_main("x = [1, 'a']")))
    eq("2:16: expected None, received int", check_errors(in_main("x = [None, 1]")))
    eq("2:9: cannot infer the element type of an empty list", check_errors(in_main("x = []")))
    eq("2:9: cannot infer the key and value types of an empty dict", check_errors(in_main("x = {}")))
    eq("2:10: dictionary keys must be int or str", check_errors(in_main("x = {1.5: 2}")))
    eq("2:18: expected str, received int", check_errors(in_main("x = {'a': 1, 2: 2}")))
    eq("3:27: expected list[int | None], received list[int]",
      check_errors(in_main("x = [1]\ny: list[int | None] = x")))
  end,

  collection_operations = function()
    check_source(in_main(table.concat({
      "xs: list[int | None] = [1]",
      "d: dict[str, int | None] = {}",
      "a: int | None = xs[0]",
      "b: int | None = xs.pop()",
      "c: int | None = d.get('a')",
      "e: int | None = d.pop('a')",
      "n = len(xs) + len(d)",
      "f = None in xs and 'a' not in d",
      "xs[0] = None",
      "d['a'] = 1",
    }, "\n")))
    eq("3:16: expected int, received int | None", check_errors(in_main("d = {'a': 1}\ny: int = d.get('a')")))
    eq("3:11: expected int, received str", check_errors(in_main("x = [1]\ny = x['a']")))
    eq("3:11: expected str, received int", check_errors(in_main("x = {'a': 1}\ny = x[1]")))
    eq("3:10: cannot index a value of type int", check_errors(in_main("x = 1\ny = x[0]")))
    eq("3:6: cannot index a value of type int", check_errors(in_main("x = 1\nx[0] = 1")))
    eq("3:13: expected int, received str", check_errors(in_main("xs = [1]\nxs[0] = 'a'")))
    eq("3:7: type list[int] has no method 'push'", check_errors(in_main("x = [1]\nx.push(1)")))
    eq("3:7: 'append' expects 1 argument, received 0", check_errors(in_main("x = [1]\nx.append()")))
    eq("3:8: type list[int] | None has no method 'append'",
      check_errors(in_main("xs: list[int] | None = None\nxs.append(1)")))
    eq("2:9: 'len' cannot be applied to int", check_errors(in_main("x = len(3)")))
    eq("3:13: operator 'in' cannot be applied to list[int] and list[list[int]]",
      check_errors(in_main("x = [[1]]\ny = [1] in x")))
    eq("3:11: operator 'in' cannot be applied to int and dict[str, int]",
      check_errors(in_main("d = {'a': 1}\ny = 1 in d")))
    eq("2:13: operator '==' cannot be applied to list[int] and list[int]", check_errors(in_main("x = [1] == [1]")))
    eq("2:11: cannot print a value of type list[int]", check_errors(in_main("print([1])")))
  end,

  for_loops = function()
    check_source(in_main(table.concat({
      "for x in [1]:",
      "    a: int = x",
      "for k in {'a': 1}:",
      "    b: str = k",
      "for i in range(1, 3, 1):",
      "    if i > 1:",
      "        continue",
      "    break",
      "n = 0",
      "for n in range(3):",
      "    pass",
      "print(n)",
    }, "\n")))
    eq("2:23: expected int, received str", check_errors(in_main("for x in range(1, 'a'):\n    pass")))
    eq("2:14: 'range' expects 1 to 3 arguments, received 0", check_errors(in_main("for x in range():\n    pass")))
    eq("2:9: 'range' can only be used as a 'for' iterable", check_errors(in_main("x = range(3)")))
    eq("2:14: cannot iterate over int", check_errors(in_main("for x in 3:\n    pass")))
    eq("3:5: expected str, received int", check_errors(in_main("x = 'a'\nfor x in [1]:\n    pass")))
    eq("4:11: variable 'x' may be used before assignment", check_errors(in_main("for x in [1]:\n    pass\nprint(x)")))
  end,

  index_expressions_do_not_narrow = function()
    eq("4:21: operator '+' cannot be applied to int | None and int",
      check_errors(in_main("xs: list[int | None] = [1]\nif xs[0] is not None:\n    print(xs[0] + 1)")))
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
