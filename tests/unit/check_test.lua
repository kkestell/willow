local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local diag = require("compiler.diag")

local eq = require("tests.support").eq

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
    eq("int", body[1].value.type.name)
    eq("int", body[1].symbol.type.name)
    eq("str", body[2].value.type.name)
    eq("bool", body[3].value.type.name)
    eq("int", body[3].value.operand.left.type.name)
    eq("str", body[4].symbol.type.name)
    eq("None", body[5].symbol.type.name)
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
      "h = int('7')",
      "i = float('7')",
      "j = ord('a')",
      "k = chr(97)",
    }, "\n")))
    local types = {}
    for i, statement in ipairs(program.functions[1].body) do
      types[i] = statement.value.type.name
    end
    eq("float float int float bool int float int float int str", table.concat(types, " "))
  end,

  float_type_errors = function()
    eq("2:11: operator '+' cannot be applied to int and float", check_errors(in_main("x = 1 + 1.5")))
    eq("2:11: operator '==' cannot be applied to int and float", check_errors(in_main("x = 1 == 1.0")))
    eq("2:11: operator '<' cannot be applied to int and float", check_errors(in_main("x = 1 < 1.5")))
    eq("2:13: operator '/' cannot be applied to str and str", check_errors(in_main("x = 'a' / 'b'")))
    eq("2:13: cannot convert a value of type int to int", check_errors(in_main("x = int(1)")))
    eq("2:15: cannot convert a value of type float to float", check_errors(in_main("x = float(1.5)")))
    eq("2:13: cannot convert a value of type bool to int", check_errors(in_main("x = int(True)")))
    eq("2:13: expected str, received int", check_errors(in_main("x = ord(1)")))
    eq("2:13: expected int, received str", check_errors(in_main("x = chr('a')")))
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
    eq("list[int]", program.functions[1].body[1].symbol.type.name)
    eq("dict[str, list[float]]", program.functions[1].body[2].symbol.type.name)
    eq("2:13: expected int, received str", check_errors(in_main("x = [1, 'a']")))
    eq("2:16: expected None, received int", check_errors(in_main("x = [None, 1]")))
    eq("2:9: cannot infer the element type of an empty list", check_errors(in_main("x = []")))
    eq("2:9: cannot infer the key and value types of an empty dict", check_errors(in_main("x = {}")))
    eq("2:10: dictionary keys must be int, str, or an enum", check_errors(in_main("x = {1.5: 2}")))
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
    eq("P", program.functions[1].body[1].symbol.type.name)
    eq("7:9: 'P' expects 2 arguments, received 1", check_errors(m("p = P(1)")))
    eq("7:14: expected int | None, received str", check_errors(m("p = P(1, 'a')")))
    eq("8:7: class P has no field 'z'", check_errors(m("p = P(1, None)\np.z = 1")))
    eq("8:11: class P has no field 'z'", check_errors(m("p = P(1, None)\nq = p.z")))
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
    eq("3:22: expected str, received int", check_errors(in_main("s = 'a'\nx = s.join(['a', 1])")))
    eq("3:6: cannot assign to an index of a value of type str", check_errors(in_main("s = 'a'\ns[0] = 'b'")))
    eq("2:11: operator 'in' cannot be applied to int and str", check_errors(in_main("x = 1 in 'abc'")))
    eq("2:14: operator 'in' cannot be applied to int | str and str",
      check_errors("def f(x: int | str) -> bool:\n    return x in 'a5b'\n" .. MAIN))
    eq("2:14: operator 'not in' cannot be applied to str | None and str",
      check_errors("def f(x: str | None) -> bool:\n    return x not in 'abc'\n" .. MAIN))
  end,

  methods = function()
    local C = table.concat({
      "class C:",
      "    n: int",
      "    def add(self, k: int, times: int = 1) -> int:",
      "        self.n = self.n + k * times",
      "        return self.n",
      "    def same(self, other: C) -> bool:",
      "        return self.n == other.n",
      "",
    }, "\n")
    local function m(statements)
      return C .. "def main() -> None:\n" .. statements:gsub("[^\n]+", "    %0") .. "\n"
    end
    local program = check_source(m("c = C(1)\na = c.add(2)\nb = c.add(times=3, k=1)\nok = c.same(c)"))
    local body = program.functions[1].body
    eq("int int bool", body[2].value.type.name .. " " .. body[3].value.type.name .. " " .. body[4].value.type.name)
    eq(program.records[1].methods[1], body[2].value.method)
    eq("10:7: 'add' expects 1 to 2 arguments, received 0", check_errors(m("c = C(1)\nc.add()")))
    eq("10:11: expected int, received str", check_errors(m("c = C(1)\nc.add('a')")))
    eq("10:11: 'add' has no parameter 'self'", check_errors(m("c = C(1)\nc.add(self=c, k=1)")))
    eq("10:7: type C has no method 'sub'", check_errors(m("c = C(1)\nc.sub(1)")))
    eq("10:11: class C has no field 'add'", check_errors(m("c = C(1)\nf = c.add")))
    eq("10:11: type C | None has no method 'add'", check_errors(m("cs: list[C | None] = [None]\ncs[0].add(1)")))
    check_source(m("cs: list[C | None] = [None]\nc = cs[0]\nif c is not None:\n    c.add(1)"))
    eq("3:9: method 'D.f' must return a value on every path",
      check_errors("class D:\n    x: int\n    def f(self) -> int:\n        print(self.x)\n" .. MAIN))
    eq("3:16: expected int, received D",
      check_errors("class D:\n    def f(self) -> int:\n        return self\n" .. MAIN))
  end,

  records_across_modules = function()
    local function check_modules(main_source)
      local modules = {}
      for i, source in ipairs({ { "main", "import geo\n" .. main_source }, { "geo", "class Point:\n    x: int\n    def moved(self, dx: int) -> Point:\n        return Point(self.x + dx)\n" } }) do
        local program = parser.parse(lexer.lex(source[2], source[1] .. ".wlo"))
        program.name, program.path = source[1], source[1] .. ".wlo"
        modules[i] = program
      end
      bind.bind(modules)
      check.check(modules)
    end
    check_modules("def main() -> None:\n    p = geo.Point(1)\n    q: geo.Point = p\n    print(q.x + 1)\n")
    check_modules("def main() -> None:\n    print(geo.Point(1).moved(dx=2).x)\n")
    local ok, err = pcall(check_modules, "class Point:\n    x: int\ndef main() -> None:\n    p: Point = geo.Point(1)\n")
    eq(false, ok)
    eq("5:20: expected Point, received geo.Point", err[1].span.line .. ":" .. err[1].span.col .. ": " .. err[1].message)
  end,

  equality_on_all_types = function()
    local program = check_source(in_main("a = 1 == 2\nb = True != False\nc = 'x' == 'y'\nd = None == print(1)"))
    for _, statement in ipairs(program.functions[1].body) do
      eq("bool", statement.value.type.name)
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
    eq("None", check_source(in_main("x: None = print(1)")).functions[1].body[1].symbol.type.name)
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
    eq("ParseError", body[1].symbol.type.name)
    eq("str", body[2].symbol.type.name)
    eq("int", body[3].symbol.type.name)
    eq("4:9: 'ParseError' expects 2 arguments, received 1", check_errors(E .. in_main("e = ParseError('bad')")))
    check_source(E .. "def f(e: ParseError | None) -> Exception | None:\n    return e\n" .. MAIN)
    eq("5:26: expected list[Exception], received list[ParseError]",
      check_errors(E .. in_main("x: list[ParseError] = []\ny: list[Exception] = x")))
    eq("5:11: class Exception has no field 'line'",
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
    eq("KeyError", program.functions[1].locals[1].type.name)
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

  io_builtins = function()
    local function with_modules(source)
      return "import sys\nimport fs\n" .. source
    end
    eq("5:5: unreachable statement", check_errors(with_modules(in_main("sys.exit(0)\nprint(1)"))))
    check_source(with_modules("def f() -> int:\n    sys.exit(1)\n" .. MAIN))
    check_source("def exit(status: int) -> None:\n    pass\n" .. in_main("exit(0)\nprint(1)"))
    eq("3:9: 'len' cannot be applied to str | None", check_errors(in_main("line = input()\nn = len(line)")))
    local program = check_source(with_modules(in_main("args = sys.args()")))
    eq("list[str]", program.functions[1].body[1].symbol.type.name)
    check_source(with_modules(in_main("line = input()\nif line is not None:\n    fs.write_file('out.txt', fs.read_file(line))")))
    eq("4:14: expected int, received str", check_errors(with_modules(in_main("sys.exit('x')"))))
    eq("4:8: 'fs.write_file' expects 2 arguments, received 1", check_errors(with_modules(in_main("fs.write_file('a')"))))
    eq("4:16: cannot print a value of type list[int]", check_errors(with_modules(in_main("sys.eprint([1])"))))
    check_source(with_modules(in_main("try:\n    sys.eprint(fs.read_file('a'))\nexcept OSError as error:\n    sys.eprint(error.message)")))
  end,

  aliases_and_union_assignability = function()
    local json = "type Json = None | bool | int | float | str | list[Json] | dict[str, Json]\n"
    check_source(json .. in_main(table.concat({
      "a: list[Json] = []",
      "b: list[None | bool | int | float | str | list[Json] | dict[str, Json]] = a",
      "a = b",
      "c: list[int | str] = []",
      "d: list[str | int] = c",
      "e: int | str | None = 1",
      "f: int | None = None",
      "e = f",
      "j: Json = {'a': [1, 2.5, None, {'b': True}]}",
      "k: int | list[int] = []",
      "m: dict[str, int] | None = {}",
    }, "\n")))
    eq("3:21: expected int | None, received int | str | None",
      check_errors(in_main("e: int | str | None = None\nf: int | None = e")))
    eq("3:26: expected list[int | str], received list[int]",
      check_errors(in_main("a: list[int] = []\nb: list[int | str] = a")))
    eq("4:15: expected Json, received list[int]", check_errors(json .. in_main("y = [1]\nx: Json = y")))
    eq("2:13: expected int, received str", check_errors(in_main("x = [1, 'a']")))
  end,

  union_operations = function()
    -- `f` starts on line 1 with parameters x and y.
    local function f(statements)
      return "def f(x: int | str, y: int | list[int]) -> None:\n" .. statements:gsub("[^\n]+", "    %0") .. "\n" .. MAIN
    end
    check_source(f("b = x == 1 or x != 'a'\nprint(x)\nz = f'{x}' + str(x)"))
    eq("2:11: operator '==' cannot be applied to int | str and float", check_errors(f("b = x == 1.5")))
    eq("2:11: operator '==' cannot be applied to int | str and None", check_errors(f("b = x == None")))
    eq("2:11: cannot print a value of type int | list[int]", check_errors(f("print(y)")))
    eq("2:11: operator '+' cannot be applied to int | str and int", check_errors(f("b = x + 1")))
    eq("2:23: type int | str has no member float", check_errors(f("b = isinstance(x, float)")))
    eq("2:23: type int has no member str", check_errors(in_main("y = isinstance(1, str)")))
    check_source(in_main("y = isinstance(1, int)"))
  end,

  isinstance_narrowing = function()
    -- `f` starts on line 1 with parameter x.
    local function f(statements)
      return "class P:\n    v: int\ndef f(x: int | str | list[int] | P | None) -> None:\n"
        .. statements:gsub("[^\n]+", "    %0") .. "\n" .. MAIN
    end
    local valid = {
      "if isinstance(x, int):\n    print(x + 1)\nelif isinstance(x, str):\n    print(x + 'a')\nelif isinstance(x, list):\n"
        .. "    x.append(1)\nelif x is not None:\n    print(x.v)",
      "if isinstance(x, P) and x.v > 0:\n    print(x.v)",
      "if not isinstance(x, int) or x > 0:\n    pass",
      "if x is None or isinstance(x, list) or isinstance(x, P):\n    return\nif isinstance(x, int):\n    return\nprint(x + 'a')",
      "x = 'a'\nprint(x + 'b')",
      "x = [1]\nx.append(2)",
      "x = P(1)\nprint(x.v)",
    }
    for _, statements in ipairs(valid) do
      check_source(f(statements))
    end
    -- After the if, x has the members either falling-through branch left.
    local program = check_source(f("if isinstance(x, int):\n    pass\nelif isinstance(x, str):\n    pass\nelse:\n    return\ny = x"))
    eq("int | str", program.functions[1].body[2].value.type.name)
    -- `or` has no true facts.
    eq("5:17: operator '+' cannot be applied to int | str | list[int] | P | None and int",
      check_errors(f("if isinstance(x, int) or isinstance(x, str):\n    print(x + 1)")))
    eq("7:13: operator '+' cannot be applied to int | str | list[int] | P | None and int",
      check_errors(f("if not isinstance(x, int):\n    return\nx = None\nprint(x + 1)")))
    eq("7:17: operator '+' cannot be applied to int | str | list[int] | P | None and int",
      check_errors(f("if not isinstance(x, int):\n    return\nwhile True:\n    print(x + 1)\n    x = None")))
  end,

  text_and_collections = function()
    local program = check_source(in_main(table.concat({
      "s = 'abc'",
      "xs = [3, 1]",
      "c: str = s[-1] + s[1:] + s[:2].upper().lower()",
      "ys: list[int] = xs[:]",
      "zs: list[int] = sorted(xs)",
      "zs = sorted(xs, True)",
      "ws: list[str] = sorted(['b', 'a'], reverse=True)",
      "xs.sort()",
      "xs.sort(reverse=False)",
      "t: str = s.ljust(5) + s.rjust(-1)",
      "v: int | str = 1",
      "f: str = f'{s:s}{1:>3d}{1.5:.2f}{v:>5}{True:^4}'",
    }, "\n")))
    eq("str", program.functions[1].body[3].value.type.name)
    eq("2:15: cannot slice a value of type dict[int, int]", check_errors(in_main("x = {1: 2}[1:]")))
    eq("3:11: expected int, received str", check_errors(in_main("s = 'a'\nx = s['a':]")))
    eq("2:16: cannot sort a value of type list[bool]", check_errors(in_main("x = sorted([True])")))
    eq("3:16: cannot sort a value of type list[int | None]",
      check_errors(in_main("x: list[int | None] = []\ny = sorted(x)")))
    eq("3:16: cannot sort a value of type list[P]", check_errors(in_main("x = [P(1)]\ny = sorted(x)", "class P:\n    n: int\n")))
    eq("2:9: 'sorted' expects 1 to 2 arguments, received 3", check_errors(in_main("x = sorted([1], True, True)")))
    eq("3:7: 'sort' expects 0 to 1 arguments, received 2", check_errors(in_main("x = [1]\nx.sort(True, True)")))
    eq("2:11: 'print' does not accept keyword arguments", check_errors(in_main("print(end='')")))
    eq("2:21: 'sorted' has no parameter 'key'", check_errors(in_main("x = sorted([1], key=True)")))
    eq("2:9: 'sorted' is missing argument 'items'", check_errors(in_main("x = sorted(reverse=True)")))
    eq("3:16: expected int, received None", check_errors(in_main("x = [1]\ny: int = x.sort()")))
    eq("2:12: format type 'd' requires int, received str", check_errors(in_main("x = f'{\"a\":d}'")))
    eq("2:12: format type 'f' requires float, received int", check_errors(in_main("x = f'{1:f}'")))
    eq("2:15: format type 'd' requires int, received int | str",
      check_errors("def f(v: int | str) -> str:\n    return f'{v:d}'\n" .. MAIN))
    check_source(in_main("sorted = 1\nprint(sorted)"))
    eq("1:5: cannot redefine built-in function 'sorted'", check_errors("def sorted() -> None:\n    pass\n" .. MAIN))
  end,

  named_arguments = function()
    local F = "def f(a: int, b: str = 'x', c: float = 1.5) -> None:\n    pass\n"
    local P = "class P:\n    x: int\n    y: int = 0\n"
    local E = "class E(Exception):\n    code: int = 1\n"
    check_source("import fs\n" .. in_main(table.concat({
      "f(1)",
      "f(1, c=2.5)",
      "f(c=2.5, a=1, b='y')",
      "p = P(y=2, x=1)",
      "q = P(1)",
      "e = E('m')",
      "e = E(code=2, message='m')",
      "fs.write_file(text='x', path='p')",
      "t: str = fs.read_file(path='p')",
      "xs = sorted(items=[2, 1], reverse=True)",
    }, "\n"), F .. P .. E))
    check_source("import sys\ndef g(x: int | None = None, y: float | int = 2.0) -> int:\n"
      .. "    sys.exit(status=1)\n" .. MAIN)
    eq("1:16: expected int, received str", check_errors("def g(x: int = 'a') -> None:\n    pass\n" .. MAIN))
    eq("4:14: expected str, received None", check_errors(MAIN .. "class Q:\n    s: str = None\n"))
    eq("2:10: 'f' has no parameter 'd'", check_errors(in_main("f(1, d=2)", F)))
    eq("2:11: 'P' has no field 'z'", check_errors(in_main("x = P(z=1)", P)))
    eq("2:10: 'f' received more than one value for 'a'", check_errors(in_main("f(1, a=2)", F)))
    eq("2:14: 'f' received more than one value for 'b'", check_errors(in_main("f(b='y', b='z', a=1)", F)))
    eq("2:5: 'f' is missing argument 'a'", check_errors(in_main("f(b='y', c=1.0)", F)))
    eq("2:5: 'f' expects 1 to 3 arguments, received 4", check_errors(in_main("f(1, 'a', 1.0, 2)", F)))
    eq("2:5: 'f' expects 1 to 3 arguments, received 0", check_errors(in_main("f()", F)))
    eq("2:13: 'len' does not accept keyword arguments", check_errors(in_main("x = len(value='a')")))
    eq("3:16: 'find' does not accept keyword arguments", check_errors(in_main("s = 'a'\nx = s.find(sub='a')")))
    eq("2:20: 'range' does not accept keyword arguments", check_errors(in_main("for i in range(stop=3):\n    pass")))
    eq("4:5: unreachable statement", check_errors("import sys\n" .. in_main("sys.exit(status=1)\nprint(1)")))
  end,

  assertions = function()
    check_source("def f(x: int | None, v: int | str) -> int:\n"
      .. "    assert isinstance(v, int), v\n    assert x is not None\n    return x + v\n" .. MAIN)
    check_source(in_main("assert False\nprint(1)"))
    eq("2:12: expected bool, received int", check_errors(in_main("assert 1")))
    eq("2:20: expected str, received int", check_errors(in_main("assert 1 == 1, 2")))
    eq("1:5: function 'f' must return a value on every path",
      check_errors("def f() -> int:\n    assert False\n" .. MAIN))
    eq("6:11: variable 'y' may be used before assignment",
      check_errors(in_main("c = True\nif c:\n    y = 1\nassert c\nprint(y)")))
  end,

  host_modules = function()
    local program = check_source("import fs\nimport sys\nimport time\n" .. in_main(table.concat({
      "s: fs.Stat = fs.stat(path='x', follow_symlinks=False)",
      "k = s.kind",
      "made = fs.Stat(kind='file', size=1, modified=0.5)",
      "names: list[str] = fs.listdir('.')",
      "env: dict[str, str] = sys.environ()",
      "fs.mkdir('d', exist_ok=True)",
      "t: str = time.utc(time.time())",
      "e = TimeoutError('slow')",
    }, "\n")))
    eq("str", program.functions[1].body[2].value.type.name)
    eq("3:25: operator '+' cannot be applied to str | None and str",
      check_errors("import sys\n" .. in_main("x = sys.getenv('A') + 'b'")))
    eq("3:16: expected float, received int", check_errors("import time\n" .. in_main("time.sleep(1)")))
  end,

  bytes_and_files = function()
    local program = check_source("import io\n" .. in_main(table.concat({
      "b: bytes = bytes([1, 2]) + 'é'.encode()",
      "n: int = len(b) + b[-1]",
      "c: bytes = b[1:]",
      "for x in b:",
      "    n = n + x",
      "t: str = b.decode()",
      "same: bool = b == c",
      "v: bytes | str = 'a'",
      "other: bool = v == 'a'",
      "f: io.File = io.open('x', mode='w')",
      "d = io.stdin().read(size=4)",
      "line: str | None = f.readline()",
      "f.write(data=b)",
      "f.write_text('x')",
      "f.close()",
    }, "\n")))
    eq("bytes", program.functions[1].body[10].value.type.name)
    local function err(statement)
      return check_errors("import io\n" .. in_main("b = bytes([1])\n" .. statement))
    end
    eq("4:11: cannot print a value of type bytes", err("print(b)"))
    eq("4:12: cannot format a value of type bytes", err("x = f'{b}'"))
    eq("4:13: cannot convert a value of type bytes to str", err("x = str(b)"))
    eq("4:11: operator '<' cannot be applied to bytes and bytes", err("x = b < b"))
    eq("4:11: operator '+' cannot be applied to bytes and str", err("x = b + 'a'"))
    eq("4:6: cannot assign to an index of a value of type bytes", err("b[0] = 1"))
    eq("4:16: expected int, received str", err("x = bytes(['a'])"))
    eq("4:12: cannot construct native type io.File", err("x = io.File()"))
    eq("5:11: type io.File has no field 'path'", err("f = io.stdin()\nx = f.path"))
    eq("5:11: operator '==' cannot be applied to io.File and io.File", err("f = io.stdin()\nx = f == f"))
    eq("5:11: cannot print a value of type io.File", err("f = io.stdin()\nprint(f)"))
    eq("1:15: dictionary keys must be int, str, or an enum", check_errors("def f(d: dict[bytes, int]) -> None:\n    pass\n" .. MAIN))
    eq("2:5: expected an expression, found 'bytes'", check_errors(in_main("bytes = 1")))
  end,

  subprocess_module = function()
    local program = check_source("import subprocess\n" .. in_main(table.concat({
      "r = subprocess.run(['x'], capture_output=True, timeout=1.5)",
      "out = r.stdout",
      "if out is not None:",
      "    print(len(out))",
      "p = subprocess.spawn(['sleep', '1'], cwd='/')",
      "code: int = p.wait(timeout=1.0)",
      "status: int | None = p.poll()",
      "p.terminate()",
      "p.kill()",
    }, "\n")))
    eq("subprocess.Result", program.functions[1].body[1].value.type.name)
    local function err(statement)
      return check_errors("import subprocess\n" .. in_main(statement))
    end
    eq("4:12: expected float | None, received int", err("p = subprocess.spawn(['x'])\np.wait(1)"))
    eq("3:20: cannot construct native type subprocess.Process", err("p = subprocess.Process()"))
    eq("3:20: expected list[str], received str", err("subprocess.run('x')"))
    eq("3:59: operator '+' cannot be applied to bytes | None and int",
      err("x = subprocess.run(['x'], capture_output=True).stdout + 1"))
  end,

  cli_and_terminal = function()
    local program = check_source("import cli\nimport terminal\n" .. in_main(table.concat({
      "p = cli.parser('tool', description='Does things')",
      "p.add_int('limit', 10, short='n')",
      "p.add_flag('verbose')",
      "a = p.parse(['-n', '2'])",
      "n: int = a.get_int('limit')",
      "f: float = a.get_float('x')",
      "b: bool = a.get_bool('verbose')",
      "rest: list[str] = a.get_list('rest')",
      "try:",
      "    p.parse([])",
      "except cli.UsageError as e:",
      "    print(e.message)",
      "t: str = terminal.style('x', color='red', bold=True, enabled=False)",
    }, "\n")))
    eq("cli.Args", program.functions[1].body[4].value.type.name)
    local function err(statement)
      return check_errors("import cli\n" .. in_main("p = cli.parser('tool')\n" .. statement))
    end
    eq("4:20: expected int, received str", err("p.add_int('n', 'x')"))
    eq("4:13: cannot construct native type cli.Parser", err("q = cli.Parser()"))
  end,

  net_module = function()
    local program = check_source("import net\n" .. in_main(table.concat({
      "c = net.connect('localhost', 80)",
      "data = c.recv(4, timeout=1.0)",
      "l = net.listen('127.0.0.1', 0, backlog=4)",
      "a = l.accept(timeout=1.0)",
      "port: int = l.local_port()",
      "c.sendall(data)",
    }, "\n")))
    eq("bytes", program.functions[1].body[2].value.type.name)
    eq("net.Connection", program.functions[1].body[4].value.type.name)
    eq("3:13: cannot construct native type net.Connection", check_errors("import net\n" .. in_main("x = net.Connection()")))
    eq("4:12: expected int, received str",
      check_errors("import net\n" .. in_main("c = net.connect('h', 1)\nc.recv('x')")))
  end,

  tuples = function()
    local PAIR = "def pair() -> tuple[int, str]:\n    return (1, 'a')\n"
    eq("2:16: tuple index out of range", check_errors(in_main("x = pair()[2]", PAIR)))
    eq("2:16: tuple index out of range", check_errors(in_main("x = pair()[-3]", PAIR)))
    eq("3:16: tuple index must be an integer literal", check_errors(in_main("i = 0\nx = pair()[i]", PAIR)))
    eq("3:6: cannot assign to an index of a value of type tuple[int, str]", check_errors(in_main("t = pair()\nt[0] = 1", PAIR)))
    eq("2:15: cannot slice a value of type tuple[int, str]", check_errors(in_main("x = pair()[0:1]", PAIR)))
    eq("2:7: expected tuple[int], received tuple[int, int]", check_errors(in_main("f((1, 2))", "def f(t: tuple[int]) -> None:\n    pass\n")))
    eq("2:30: expected str, received int", check_errors(in_main("x: tuple[int, str] = (1, 2)")))
    eq("2:25: type int | str has no member tuple", check_errors(in_main("x = isinstance(f(), tuple)", "def f() -> int | str:\n    return 1\n")))
    eq("2:11: cannot print a value of type tuple[int]", check_errors(in_main("print((1,))")))
  end,

  tuple_comparisons_and_iteration = function()
    eq("2:18: operator '==' cannot be applied to tuple[int, str] and tuple[int, int]",
      check_errors(in_main("x = (1, 'a') == (1, 2)")))
    eq("2:14: operator '==' cannot be applied to tuple[int] and tuple[int, int]", check_errors(in_main("x = (1,) == (1, 2)")))
    eq("2:18: operator '==' cannot be applied to tuple[int, list[int]] and tuple[int, list[int]]",
      check_errors(in_main("x = (1, [1]) == (1, [1])")))
    eq("2:18: operator '<' cannot be applied to tuple[int, str] and tuple[int, None]",
      check_errors(in_main("x = (1, 'a') < (1, None)")))
    eq("2:14: operator '<' cannot be applied to tuple[int] and tuple[float]", check_errors(in_main("x = (1,) < (1.5,)")))
    eq("2:14: cannot iterate over tuple[list[int], list[str]]: a union can have only one list member",
      check_errors(in_main("for x in ([1], ['a']):\n    pass")))
    eq("2:11: operator 'in' cannot be applied to int and tuple[int, int]", check_errors(in_main("x = 1 in (1, 2)")))
  end,

  enums = function()
    local E = "enum E:\n    A\n    B\nenum F:\n    A\n"
    eq("2:13: operator '<' cannot be applied to E and E", check_errors(in_main("x = E.A < E.B", E)))
    eq("2:13: operator '==' cannot be applied to E and F", check_errors(in_main("x = E.A == F.A", E)))
    eq("2:13: operator '==' cannot be applied to E and str", check_errors(in_main("x = E.A == 'A'", E)))
    eq("2:15: cannot convert a value of type E to int", check_errors(in_main("x = int(E.A)", E)))
    eq("2:14: format type 's' requires str, received E", check_errors(in_main("x = f'{E.A:s}'", E)))
    eq("1:14: union members E and E overlap", check_errors("def f(x: E | E) -> None:\n    pass\n" .. E .. MAIN))
    eq("3:18: expected E, received F", check_errors("def f(x: E | F) -> E:\n    if isinstance(x, E):\n        return F.A\n"
      .. "    return E.A\n" .. E .. MAIN))
    eq("2:20: expected E, received F", check_errors(in_main("x = {E.A: 1, F.A: 2}", E)))
  end,
}
