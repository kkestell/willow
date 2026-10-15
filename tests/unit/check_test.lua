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
  bind.bind({ program })
  check.check({ program })
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
    eq("2:14: operator '<' cannot be applied to bool and bool", check_errors(in_main("x = True < False")))
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

  records = function()
    local P = "class P:\n    x: int\n    y: int | None\nclass Bag:\n    items: list[int]\n"
    local function m(statements)
      return P .. "def main() -> None:\n" .. statements:gsub("[^\n]+", "    %0") .. "\n"
    end
    local program = check_source(m("p = P(1, None)\nq = P(2, 3)\ny: int = p.x\nb = Bag([])\nb.items = []\np.y = None"))
    eq("P", program.functions[1].body[1].symbol.type)
    eq("7:9: 'P' expects 2 arguments, received 1", check_errors(m("p = P(1)")))
    eq("7:14: expected int | None, received str", check_errors(m("p = P(1, 'a')")))
    eq("8:7: record P has no field 'z'", check_errors(m("p = P(1, None)\np.z = 1")))
    eq("8:11: record P has no field 'z'", check_errors(m("p = P(1, None)\nq = p.z")))
    eq("8:11: expected int, received str", check_errors(m("p = P(1, None)\np.x = 'a'")))
    eq("8:11: type int has no field 'z'", check_errors(m("x = 1\ny = x.z")))
    eq("8:12: type list[int] has no field 'append'", check_errors(m("xs = [1]\ny = xs.append")))
    eq("8:11: type P | None has no field 'x'", check_errors(m("p: P | None = None\ny = p.x")))
    eq("8:11: operator '==' cannot be applied to P and P", check_errors(m("p = P(1, None)\nb = p == p")))
    eq("8:11: cannot print a value of type P", check_errors(m("p = P(1, None)\nprint(p)")))
    eq("6:12: expected A, received B",
      check_errors("class A:\n    x: int\nclass B:\n    x: int\ndef main() -> None:\n    a: A = B(1)\n"))
  end,

  field_expressions_do_not_narrow = function()
    eq("7:17: operator '+' cannot be applied to int | None and int", check_errors(
      "class P:\n    x: int\n    y: int | None\ndef main() -> None:\n    p = P(1, None)\n"
      .. "    if p.y is not None:\n        z = p.y + 1\n"))
  end,

  strings = function()
    check_source(in_main(table.concat({
      "s = 'a'",
      "b = s < 'b' and s.startswith('a') and s.endswith('a') and 'a' in s",
      "n: int = s.find('a') + len(s)",
      "t: str = s.replace('a', 'b').strip()",
      "parts: list[str] = s.split(',')",
      "u: str = ','.join(parts)",
      "v: str = f'{n}{b}{None}{1.5}{s}' + str(n) + str(None)",
      "for ch in s:",
      "    w: str = ch",
    }, "\n")))
    eq("2:12: cannot format a value of type list[int]", check_errors(in_main("x = f'{[1]}'")))
    eq("2:13: cannot convert a value of type list[int] to str", check_errors(in_main("x = str([1])")))
    eq("2:12: unknown name 'y'", check_errors(in_main("x = f'{y}'")))
    eq("3:16: expected str, received int", check_errors(in_main("s = 'a'\nx = s.find(1)")))
    eq("3:11: type str has no method 'upper'", check_errors(in_main("s = 'a'\nx = s.upper()")))
    eq("3:22: expected str, received int", check_errors(in_main("s = 'a'\nx = s.join(['a', 1])")))
    eq("3:10: cannot index a value of type str", check_errors(in_main("s = 'a'\nx = s[0]")))
    eq("2:11: operator 'in' cannot be applied to int and str", check_errors(in_main("x = 1 in 'abc'")))
  end,

  records_across_modules = function()
    local function check_modules(main_source)
      local modules = {}
      for i, source in ipairs({ { "main", "import geo\n" .. main_source }, { "geo", "class Point:\n    x: int\n" } }) do
        local program = parser.parse(lexer.lex(source[2], source[1] .. ".wlo"))
        program.name, program.path = source[1], source[1] .. ".wlo"
        modules[i] = program
      end
      bind.bind(modules)
      check.check(modules)
    end
    check_modules("def main() -> None:\n    p = geo.Point(1)\n    q: geo.Point = p\n    print(q.x + 1)\n")
    local ok, err = pcall(check_modules, "class Point:\n    x: int\ndef main() -> None:\n    p: Point = geo.Point(1)\n")
    eq(false, ok)
    eq("5:20: expected Point, received geo.Point", err[1].span.line .. ":" .. err[1].span.col .. ": " .. err[1].message)
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

  exception_classes = function()
    local E = "class ParseError(Exception):\n    line: int\n"
    local program = check_source(E .. in_main("e = ParseError('bad', 2)\nm = e.message\nn = e.line\nb: Exception = e\nc: Exception | None = None\nc = ValueError('x')"))
    local body = program.functions[1].body
    eq("ParseError", body[1].symbol.type)
    eq("str", body[2].symbol.type)
    eq("int", body[3].symbol.type)
    eq("4:9: 'ParseError' expects 2 arguments, received 1", check_errors(E .. in_main("e = ParseError('bad')")))
    check_source(E .. "def f(e: ParseError | None) -> Exception | None:\n    return e\n" .. MAIN)
    eq("5:26: expected list[Exception], received list[ParseError]",
      check_errors(E .. in_main("x: list[ParseError] = []\ny: list[Exception] = x")))
    eq("5:11: record Exception has no field 'line'",
      check_errors(E .. in_main("e: Exception = ParseError('bad', 2)\nx = e.line")))
    eq("4:11: cannot print a value of type Exception", check_errors(E .. in_main("print(Exception('x'))")))
  end,

  raise_operands = function()
    eq("2:11: expected an exception, received int", check_errors(in_main("raise 1")))
    eq("3:11: expected an exception, received Exception | None",
      check_errors(in_main("e: Exception | None = None\nraise e")))
    check_source("def f(n: int) -> int:\n    if n > 0:\n        return n\n    raise ValueError('negative')\n" .. MAIN)
    eq("3:5: unreachable statement", check_errors(in_main("raise ValueError('x')\nprint(1)")))
  end,

  except_clauses = function()
    local function try(clauses)
      return in_main("try:\n    pass\n" .. clauses)
    end
    eq("6:5: unreachable 'except' clause",
      check_errors(try("except Exception:\n    pass\nexcept ValueError:\n    pass")))
    eq("6:5: unreachable 'except' clause",
      check_errors(try("except ValueError:\n    pass\nexcept ValueError:\n    pass")))
    local program = check_source(try("except KeyError as e:\n    m = e.message\nexcept Exception as other:\n    pass"))
    eq("KeyError", program.functions[1].locals[1].type)
    eq("6:5: expected KeyError, received IndexError",
      check_errors(try("except KeyError as e:\n    pass\nexcept IndexError as e:\n    pass")))
    check_source(in_main("e: Exception = ValueError('x')\ntry:\n    pass\nexcept KeyError as e:\n    pass"))
  end,

  finally_departures = function()
    local function in_finally(statements)
      return in_main("while True:\n    try:\n        pass\n    finally:\n" .. statements:gsub("[^\n]+", "        %0"))
    end
    eq("6:13: 'return' cannot leave a 'finally' clause", check_errors(in_finally("return")))
    eq("6:13: 'break' cannot leave a 'finally' clause", check_errors(in_finally("break")))
    eq("7:17: 'continue' cannot leave a 'finally' clause", check_errors(in_finally("if True:\n    continue")))
    check_source(in_finally("while True:\n    break"))
    check_source(in_main("while True:\n    try:\n        break\n    except Exception:\n        continue"))
  end,

  try_transfers = function()
    check_source("def f() -> int:\n    try:\n        return 1\n    except Exception:\n        return 2\n" .. MAIN)
    check_source("def f() -> int:\n    try:\n        pass\n    finally:\n        raise ValueError('x')\n" .. MAIN)
    eq("1:5: function 'f' must return a value on every path",
      check_errors("def f() -> int:\n    try:\n        return 1\n    except Exception:\n        pass\n" .. MAIN))
    eq("6:5: unreachable statement",
      check_errors(in_main("try:\n    return\nexcept Exception:\n    return\nprint(1)")))
  end,

  try_flow = function()
    local function f(statements)
      return "def f(x: int | None) -> None:\n" .. statements:gsub("[^\n]+", "    %0") .. "\n" .. MAIN
    end
    eq("5:15: variable 'y' may be used before assignment",
      check_errors(f("try:\n    y = 1\nexcept Exception:\n    print(y)")))
    eq("5:15: variable 'y' may be used before assignment",
      check_errors(f("try:\n    y = 1\nfinally:\n    print(y)")))
    check_source(f("try:\n    y = 1\nexcept Exception:\n    y = 2\nprint(y)"))
    check_source(f("try:\n    y = 1\nexcept Exception:\n    return\nprint(y)"))
    eq("6:11: variable 'y' may be used before assignment",
      check_errors(f("try:\n    y = 1\nexcept Exception:\n    pass\nprint(y)")))
    check_source(f("try:\n    pass\nfinally:\n    y = 1\nprint(y)"))
    -- Narrowing before the try holds in a clause only for locals the body does not assign.
    check_source(f("if x is None:\n    return\ntry:\n    pass\nexcept Exception:\n    print(x + 1)"))
    eq("7:17: operator '+' cannot be applied to int | None and int",
      check_errors(f("if x is None:\n    return\ntry:\n    x = None\nexcept Exception:\n    print(x + 1)")))
    eq("9:17: operator '+' cannot be applied to int | None and int",
      check_errors(f("if x is None:\n    return\ntry:\n    pass\nexcept Exception:\n    x = None\nfinally:\n    print(x + 1)")))
    check_source(f("try:\n    x = 1\nexcept Exception:\n    return\nprint(x + 1)"))
    check_source(f("try:\n    pass\nfinally:\n    if x is None:\n        raise ValueError('x')\nprint(x + 1)"))
    eq("7:13: operator '+' cannot be applied to int | None and int",
      check_errors(f("try:\n    y: int | None = 1\nfinally:\n    if x is None:\n        y = None\nprint(y + 1)")))
  end,
}
