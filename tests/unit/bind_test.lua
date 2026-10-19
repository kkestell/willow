local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local diag = require("compiler.diag")

local eq = require("tests.support").eq

local function bind_source(source)
  local program = parser.parse(lexer.lex(source))
  bind.bind({ program })
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
  return string.format("%d:%d: %s", err[1].span.line, err[1].span.col, err[1].message)
end

local MAIN = "def main() -> None:\n    pass\n"

-- Parses a list of { name, source } pairs into a module list, entry first.
local function bind_modules(sources)
  local modules = {}
  for i, source in ipairs(sources) do
    local path = source[1] .. ".wlo"
    local program = parser.parse(lexer.lex(source[2], path))
    program.name, program.path = source[1], path
    modules[i] = program
  end
  bind.bind(modules)
  return modules
end

local function modules_error(sources)
  local ok, err = pcall(bind_modules, sources)
  if ok then
    error("expected a binding error", 2)
  end
  if not diag.is(err) then
    error(err, 0)
  end
  local d = err[1]
  return string.format("%s:%d:%d: %s", d.span.path, d.span.line, d.span.col, d.message)
end

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
    local message = "1:5: main must take no parameters and return None"
    eq(message, bind_error("def main(args: list[str]) -> None:\n    pass\n"))
    eq(message, bind_error("def main(x: int) -> None:\n    pass\n"))
    eq(message, bind_error("def main() -> int:\n    return 0\n"))
  end,

  standard_modules = function()
    local program = bind_source(table.concat({
      "import sys",
      "import fs",
      "def main() -> None:",
      "    a = sys.args()",
      "    sys.exit(0)",
      "    b = fs.read_file('a')",
      "",
    }, "\n"))
    local body = program.functions[1].body
    eq("Builtin", body[1].value.target.kind)
    eq("args", body[1].value.target.name)
    eq("exit", body[2].call.target.name)
    eq("read_file", body[3].value.target.name)
    eq("3:9: module 'sys' has no function, class, enum, or alias 'missing'",
      bind_error("import sys\ndef main() -> None:\n    sys.missing()\n"))
    eq("3:11: module 'sys' cannot be used as a value", bind_error("import sys\ndef main() -> None:\n    print(sys)\n"))
    bind_source("def exit(status: int) -> None:\n    pass\ndef eprint(x: int) -> None:\n    exit(x)\n" .. MAIN)
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

  calls_on_locals = function()
    -- A local hides a declaration or built-in of the same name, so calls use its value.
    local main = bind_source("def main() -> None:\n    print(1)\n    print = 2\n").functions[1]
    eq("CallValue", main.body[1].call.kind)
    eq(main.body[2].symbol, main.body[1].call.callee.symbol)
    local f = bind_source("def f(g: int) -> None:\n    g()\n" .. MAIN).functions[1]
    eq(f.params[1].symbol, f.body[1].call.callee.symbol)
  end,

  unknown_names_rejected = function()
    eq("2:9: unknown name 'y'", bind_error("def main() -> None:\n    x = y\n"))
    eq("2:5: unknown function 'f'", bind_error("def main() -> None:\n    f()\n"))
  end,

  function_values = function()
    local program = bind_source("def main() -> None:\n    x = main\n")
    eq(program.functions[1], program.functions[1].body[1].value.target)
    eq("FunctionValue", program.functions[1].body[1].value.kind)
    eq("2:11: function 'print' cannot be used as a value", bind_error("def main() -> None:\n    print(print)\n"))
    local geo = { "geo", "class Point:\n    x: int\ndef area(p: Point) -> int:\n    return p.x\n" }
    local modules = bind_modules({ { "main", "import geo\ndef main() -> None:\n    f = geo.area\n" }, geo })
    eq(modules[2].functions[1], modules[1].functions[1].body[1].value.target)
    eq("main.wlo:3:13: class 'geo.Point' cannot be used as a value",
      modules_error({ { "main", "import geo\ndef main() -> None:\n    f = geo.Point\n" }, geo }))
    eq("main.wlo:3:14: function 'time.time' cannot be used as a value",
      modules_error({ { "main", "import time\ndef main() -> None:\n    f = time.time\n" } }))
  end,

  records = function()
    eq("3:7: duplicate class 'A'", bind_error("class A:\n    x: int\nclass A:\n    y: int\n" .. MAIN))
    eq("3:7: duplicate class 'A'", bind_error("def A() -> None:\n    pass\nclass A:\n    y: int\n" .. MAIN))
    eq("3:5: duplicate function 'A'", bind_error("class A:\n    x: int\ndef A() -> None:\n    pass\n" .. MAIN))
    eq("1:7: cannot redefine built-in function 'len'", bind_error("class len:\n    x: int\n" .. MAIN))
    eq("3:5: duplicate field 'x'", bind_error("class A:\n    x: int\n    x: str\n" .. MAIN))
    local program = bind_source("class A:\n    b: B | None\nclass B:\n    a: A\n    self: B\n"
      .. "def main() -> None:\n    x = B(A(None), None)\n")
    eq(program.records[2], program.functions[1].body[1].value.target)
  end,

  methods = function()
    local method = "    def f(self) -> None:\n        pass\n"
    eq("4:9: duplicate method 'f'", bind_error("class A:\n" .. method .. method .. MAIN))
    eq("3:9: method 'x' has the same name as a field",
      bind_error("class A:\n    x: int\n    def x(self) -> int:\n        return 1\n" .. MAIN))
    eq("2:9: method 'message' has the same name as a field",
      bind_error("class E(Exception):\n    def message(self) -> str:\n        return ''\n" .. MAIN))
    eq("2:17: duplicate parameter 'self'", bind_error("class A:\n    def f(self, self: int) -> None:\n        pass\n" .. MAIN))
    local program = bind_source("class A:\n    def f(self, other: A) -> A:\n        return other\n" .. MAIN)
    local f = program.records[1].methods[1]
    eq(program.records[1], f.class)
    eq("A A A", f.params[1].type.name .. " " .. f.params[2].type.name .. " " .. f.return_type.name)
  end,

  unknown_types = function()
    eq("2:8: unknown type 'Missing'", bind_error("class A:\n    x: Missing\n" .. MAIN))
    eq("1:10: unknown type 'Missing'", bind_error("def f(a: Missing) -> None:\n    pass\n" .. MAIN))
    eq("2:13: unknown type 'Missing'", bind_error("def main() -> None:\n    x: list[Missing] = []\n"))
    eq("2:8: unknown type 'f'", bind_error("def main() -> None:\n    x: f = 1\ndef f() -> None:\n    pass\n"))
  end,

  locals_shadow_constructors = function()
    local P = "class P:\n    x: int\n"
    eq("CallValue", bind_source(P .. "def main() -> None:\n    P = 1\n    p = P(1)\n").functions[1].body[2].value.kind)
    bind_source(P .. "def main() -> None:\n    P = 1\n    q: P | None = None\n")
    eq("4:9: class 'P' cannot be used as a value", bind_error(P .. "def main() -> None:\n    x = P\n"))
  end,

  modules = function()
    local geo = { "geo", table.concat({
      "class Point:",
      "    x: int",
      "def make(x: int) -> Point:",
      "    return Point(x)",
      "def _hidden() -> int:",
      "    return 1",
      "class _Secret:",
      "    x: int",
      "def use() -> int:",
      "    return _hidden()",
      "def main() -> int:",
      "    return 2",
    }, "\n") .. "\n" }
    local function main(source)
      return { "main", "import geo\n" .. source }
    end
    local modules = bind_modules({ main("def main() -> None:\n    p: geo.Point = geo.make(1)\n    q = geo.Point(2)\n"), geo })
    local body = modules[1].functions[1].body
    eq(modules[2].declarations.make, body[1].value.target)
    eq(modules[2].declarations.Point, body[2].value.target)
    eq("geo.Point", body[1].annotation.name)
    eq("geo.Point", modules[2].functions[1].return_type.name)
    eq("main.wlo:2:5: duplicate function 'geo'", modules_error({ main("def geo() -> None:\n    pass\n" .. MAIN), geo }))
    eq("main.wlo:2:7: duplicate class 'geo'", modules_error({ main("class geo:\n    x: int\n" .. MAIN), geo }))
    eq("main.wlo:2:8: duplicate import 'geo'", modules_error({ main("import geo\n" .. MAIN), geo }))
    eq("main.wlo:1:8: cannot redefine built-in function 'len'",
      modules_error({ { "main", "import len\n" .. MAIN }, { "len", "def f() -> None:\n    pass\n" } }))
    eq("main.wlo:3:8: unknown module 'nope'", modules_error({ main("def main() -> None:\n    x: nope.Point = 1\n"), geo }))
    eq("main.wlo:3:8: unknown type 'geo.make'", modules_error({ main("def main() -> None:\n    x: geo.make = 1\n"), geo }))
    eq("main.wlo:3:13: module 'geo' has no function, class, enum, or alias 'nope'",
      modules_error({ main("def main() -> None:\n    x = geo.nope()\n"), geo }))
    eq("main.wlo:3:13: '_hidden' is private to module 'geo'",
      modules_error({ main("def main() -> None:\n    x = geo._hidden()\n"), geo }))
    eq("main.wlo:2:10: '_Secret' is private to module 'geo'",
      modules_error({ main("def f(s: geo._Secret) -> None:\n    pass\n" .. MAIN), geo }))
    eq("main.wlo:3:9: module 'geo' cannot be used as a value", modules_error({ main("def main() -> None:\n    x = geo\n"), geo }))
    -- A local shadows the module name, so this is a method call on an int.
    local shadowed = bind_modules({ main("def main() -> None:\n    geo = 1\n    x = geo.make(1)\n"), geo })
    eq("MethodCall", shadowed[1].functions[1].body[2].value.kind)
    eq("main.wlo:4:1: imports must come before declarations", modules_error({ { "main", "import geo\n" .. MAIN .. "import x\n" }, geo }))
  end,

  collection_builtins = function()
    eq("1:5: cannot redefine built-in function 'len'", bind_error("def len(x: int) -> int:\n    return x\n" .. MAIN))
    eq("1:5: cannot redefine built-in function 'range'", bind_error("def range() -> None:\n    pass\n" .. MAIN))
    local main = bind_source("def main() -> None:\n    range = 3\n    for i in range(3):\n        pass\n").functions[1]
    eq("CallValue", main.body[2].iterable.kind)
  end,

  for_names_are_locals = function()
    local program = bind_source("def f() -> None:\n    pass\ndef main() -> None:\n    for f in [1]:\n        print(f)\n")
    local main = program.functions[2]
    eq("f", main.locals[1].name)
    eq(main.body[1].symbol, main.body[1].body[1].call.args[1].symbol)
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

  exception_classes = function()
    eq("1:7: cannot redefine built-in class 'ValueError'", bind_error("class ValueError(Exception):\n    pass\n" .. MAIN))
    eq("2:9: class 'KeyError' cannot be used as a value", bind_error("def main() -> None:\n    x = KeyError\n"))
    local program = bind_source("def main() -> None:\n    e: Exception | None = ValueError('x')\n")
    eq("Exception | None", program.functions[1].body[1].annotation.name)
    local main = bind_source("def main() -> None:\n    ValueError = 1\n    e: ValueError = ValueError('x')\n").functions[1]
    eq("CallValue", main.body[2].value.kind)
  end,

  except_classes = function()
    local function clause(class)
      return "def f() -> None:\n    pass\nclass P:\n    x: int\ndef main() -> None:\n    try:\n        pass\n    except "
        .. class .. ":\n        pass\n"
    end
    eq("8:12: unknown type 'Missing'", bind_error(clause("Missing")))
    eq("8:12: unknown type 'f'", bind_error(clause("f")))
    eq("8:12: 'P' is not an exception class", bind_error(clause("P")))
    local program = bind_source(clause("IndexError as e"))
    local handler = program.functions[2].body[1].handlers[1]
    eq("IndexError", handler.record.type_name)
    eq(program.functions[2].locals[1], handler.symbol)
  end,

  bare_raise_only_in_except = function()
    local message = "bare 'raise' is only allowed in an 'except' clause"
    eq("2:5: " .. message, bind_error("def main() -> None:\n    raise\n"))
    eq("3:9: " .. message, bind_error("def main() -> None:\n    try:\n        raise\n    finally:\n        pass\n"))
    local program = bind_source(table.concat({
      "def main() -> None:",
      "    try:",
      "        pass",
      "    except Exception:",
      "        if True:",
      "            raise",
      "        try:",
      "            raise",
      "        finally:",
      "            raise",
    }, "\n"))
    local outer = program.functions[1].body[1]
    local handler = outer.handlers[1].body
    eq(outer, handler[1].body[1].try)
    eq(outer, handler[2].body[1].try)
    eq(outer, handler[2].finally_body[1].try)
  end,

  aliases = function()
    local program = bind_source("type Pair = Node | int\nclass Node:\n    next: Tree\ntype Tree = list[Tree] | None\n" .. MAIN)
    eq("Pair", program.aliases[1].type.name)
    eq("Tree", program.records[1].fields[1].type.name)
    eq("list[Tree]", program.records[1].fields[1].type.members[1].name)
    eq(program.aliases[2].type, program.records[1].fields[1].type.members[1].element.type)
    -- A local shadows the alias, but annotations still name it.
    program = bind_source("type N = int | None\ndef main() -> None:\n    N = 1\n    x: N = N\n")
    eq("N", program.functions[1].body[2].annotation.name)
    eq(program.functions[1].locals[1], program.functions[1].body[2].value.symbol)
    eq("3:6: duplicate alias 'f'", bind_error("def f() -> None:\n    pass\ntype f = int\n" .. MAIN))
    eq("1:6: cannot redefine built-in function 'isinstance'", bind_error("type isinstance = int\n" .. MAIN))
    eq("1:5: cannot redefine built-in function 'isinstance'", bind_error("def isinstance() -> None:\n    pass\n" .. MAIN))
    eq("3:9: alias 'N' cannot be used as a value", bind_error("type N = int\ndef main() -> None:\n    x = N\n"))
    eq("3:9: alias 'N' cannot be called", bind_error("type N = int\ndef main() -> None:\n    x = N(1)\n"))
    eq("3:23: alias 'N' cannot be used in isinstance",
      bind_error("type N = int\ndef main() -> None:\n    x = isinstance(1, N)\n"))
    eq("3:9: cannot call local variable 'isinstance'",
      bind_error("def main() -> None:\n    isinstance = 1\n    x = isinstance(1, int)\n"))
    eq("3:23: unknown type 'Nope'", bind_error("def main() -> None:\n    x = 1\n    y = isinstance(x, Nope)\n"))
  end,

  recursive_aliases = function()
    bind_source("type J = int | list[J] | dict[str, J]\ntype K = int | list[str | K]\n" .. MAIN)
    eq("1:19: alias 'Loop' expands to itself", bind_error("type Loop = int | Loop\n" .. MAIN))
    eq("2:10: alias 'A' expands to itself", bind_error("type A = B\ntype B = A\n" .. MAIN))
    eq("1:15: alias 'K' expands to itself", bind_error("type K = dict[K, int]\n" .. MAIN))
  end,

  union_members = function()
    eq("1:16: union members int and int overlap", bind_error("type T = int | int\n" .. MAIN))
    eq("3:22: union members Exception and E overlap",
      bind_error("class E(Exception):\n    pass\ntype T = Exception | E\n" .. MAIN))
    eq("1:22: a union can have only one list member", bind_error("type T = list[int] | list[str]\n" .. MAIN))
    eq("2:14: union members None and None overlap", bind_error("type N = int | None\ntype T = N | None\n" .. MAIN))
    eq("1:15: dictionary keys must be int, str, or an enum", bind_error("def f(x: dict[float, int]) -> None:\n    pass\n" .. MAIN))
    bind_source("type Key = str\ndef f(x: dict[Key, int]) -> None:\n    pass\n" .. MAIN)
  end,

  aliases_across_modules = function()
    local shapes = { "shapes", "class Circle:\n    r: float\ntype Shape = Circle | None\ntype _Hidden = int\n" }
    local modules = bind_modules({
      { "main", "import shapes\ntype Self = list[Self]\ndef main() -> None:\n    s: shapes.Shape = None\n" }, shapes })
    eq("shapes.Shape", modules[1].functions[1].body[1].annotation.name)
    eq("main.wlo:2:10: '_Hidden' is private to module 'shapes'",
      modules_error({ { "main", "import shapes\ndef f(x: shapes._Hidden) -> None:\n    pass\n" .. MAIN }, shapes }))
    eq("main.wlo:3:16: alias 'shapes.Shape' cannot be called",
      modules_error({ { "main", "import shapes\ndef main() -> None:\n    x = shapes.Shape(1)\n" }, shapes }))
  end,

  qualified_modules = function()
    local util = { "app.util", "def f() -> int:\n    return 1\n" }
    local other = { "app.other", "def g() -> int:\n    return 2\n" }
    local app = { "app", "def h() -> int:\n    return 3\n" }
    local function entry(text)
      return { "main", text }
    end
    local modules = bind_modules({ entry("import app.util\nimport app.other\ndef main() -> None:\n    print(app.util.f() + app.other.g())\n"), util, other })
    eq(modules[2].declarations.f, modules[1].functions[1].body[1].call.args[1].left.target)
    eq("main.wlo:2:8: 'app' is imported as a module and as a namespace",
      modules_error({ entry("import app.util\nimport app\n" .. MAIN), util, app }))
    eq("main.wlo:2:5: duplicate function 'app'", modules_error({ entry("import app.util\ndef app() -> None:\n    pass\n" .. MAIN), util }))
    eq("main.wlo:3:11: module 'app' cannot be used as a value",
      modules_error({ entry("import app.util\ndef main() -> None:\n    print(app)\n"), util }))
    eq("main.wlo:3:15: unknown module 'app.missing'",
      modules_error({ entry("import app.util\ndef main() -> None:\n    print(app.missing.f())\n"), util }))
    eq("main.wlo:3:20: module 'app.util' has no function, class, enum, or alias 'nope'",
      modules_error({ entry("import app.util\ndef main() -> None:\n    print(app.util.nope())\n"), util }))
    -- A local shadows the namespace, so the call stays a method call on it.
    modules = bind_modules({ entry("import app.util\ndef main() -> None:\n    app = 1\n    print(app.util.f())\n"), util })
    eq("MethodCall", modules[1].functions[1].body[2].call.args[1].kind)
  end,

  enums = function()
    local E = "enum E:\n    A\n    B\n"
    local program = bind_source(E .. "def main() -> None:\n    x = E.A\ndef f(E: int) -> None:\n    x = E.A\n")
    eq("EnumMember", program.functions[1].body[1].value.kind)
    eq(program.enums[1], program.functions[1].body[1].value.enum)
    -- A local hides the enum, so this is a field access on it.
    eq("Field", program.functions[2].body[1].value.kind)
    eq("4:5: duplicate enum member 'A'", bind_error("enum E:\n    A\n    B\n    A\n" .. MAIN))
    eq("4:6: duplicate enum 'E'", bind_error("class E:\n    x: int\n\nenum E:\n    A\n" .. MAIN))
    eq("5:9: enum 'E' cannot be used as a value", bind_error(E .. "def main() -> None:\n    x = E\n"))
    eq("5:9: enum 'E' cannot be called", bind_error(E .. "def main() -> None:\n    x = E()\n"))
    eq("5:11: enum 'E' has no member 'C'", bind_error(E .. "def main() -> None:\n    x = E.C\n"))
    eq("5:11: enum 'E' has no method 'A'", bind_error(E .. "def main() -> None:\n    x = E.A()\n"))
    eq("5:7: cannot assign to a member of enum 'E'", bind_error(E .. "def main() -> None:\n    E.A = E.B\n"))
    local geo = { "geo", E }
    local modules = bind_modules({ { "main", "import geo\ndef main() -> None:\n    x: geo.E = geo.E.B\n" }, geo })
    eq(modules[2].enums[1], modules[1].functions[1].body[1].value.enum)
    eq("geo.E", modules[1].functions[1].body[1].annotation.name)
    eq("main.wlo:3:15: enum 'geo.E' has no member 'C'",
      modules_error({ { "main", "import geo\ndef main() -> None:\n    x = geo.E.C\n" }, geo }))
    eq("main.wlo:3:13: enum 'geo.E' cannot be called",
      modules_error({ { "main", "import geo\ndef main() -> None:\n    x = geo.E()\n" }, geo }))
  end,

  enum_defaults = function()
    local E = "enum E:\n    A\n    B\nenum F:\n    A\n"
    local program = bind_source(E .. "class C:\n    e: E = E.B\ndef f(e: E = E.A) -> None:\n    pass\n" .. MAIN)
    eq("EnumMember", program.records[1].fields[1].default.kind)
    eq(program.enums[1], program.functions[1].params[1].default.enum)
    eq("6:16: enum 'E' has no member 'C'", bind_error(E .. "def f(e: E = E.C) -> None:\n    pass\n" .. MAIN))
    eq("6:16: expected F, received E", bind_error(E .. "def f(e: F = E.A) -> None:\n    pass\n" .. MAIN))
    eq("6:16: unknown enum 'q'", bind_error(E .. "def f(e: int = q.A) -> None:\n    pass\n" .. MAIN))
    local geo = { "geo", E }
    local modules = bind_modules({ { "main", "import geo\ndef f(e: geo.E = geo.E.B) -> None:\n    pass\n" .. MAIN }, geo })
    eq(modules[2].enums[1], modules[1].functions[1].params[1].default.enum)
  end,

  tuples = function()
    local program = bind_source("type Pair = tuple[int, str]\ndef f(p: Pair, e: tuple[()]) -> None:\n    pass\n" .. MAIN)
    eq("tuple[int, str]", program.functions[1].params[1].type.name)
    eq("tuple[()]", program.functions[1].params[2].type.name)
    eq("list[tuple[int, tuple[()]]]",
      bind_source("def f(x: list[tuple[int, tuple[()]]]) -> None:\n    pass\n" .. MAIN).functions[1].params[1].type.name)
    eq("1:23: a union can have only one tuple member",
      bind_error("def f(x: tuple[int] | tuple[str]) -> None:\n    pass\n" .. MAIN))
  end,

  tuple_defaults = function()
    local E = "enum E:\n    A\n"
    local program = bind_source(E .. "def f(t: tuple[E, int] = (E.A, 1)) -> None:\n    pass\n" .. MAIN)
    eq(program.enums[1], program.functions[1].params[1].default.elements[1].enum)
    eq("3:28: expected tuple[int, int], received tuple[int, str]",
      bind_error(E .. "def f(t: tuple[int, int] = (1, 'a')) -> None:\n    pass\n" .. MAIN))
  end,

  enum_dictionary_keys = function()
    local E = "enum E:\n    A\nenum F:\n    A\n"
    eq("dict[E, int]", bind_source(E .. "def f(d: dict[E, int]) -> None:\n    pass\n" .. MAIN).functions[1].params[1].type.name)
    eq("5:15: dictionary keys must be int, str, or an enum",
      bind_error(E .. "def f(d: dict[E | F, int]) -> None:\n    pass\n" .. MAIN))
  end,
}
