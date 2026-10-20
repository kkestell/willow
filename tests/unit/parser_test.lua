local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local diag = require("compiler.diag")

local eq = require("tests.support").eq

local function parse(source)
  return parser.parse(lexer.lex(source))
end

local function parse_error(source)
  local ok, err = pcall(parse, source)
  if ok then
    error("expected a syntax error", 2)
  end
  if not diag.is(err) then
    error(err, 0)
  end
  return string.format("%d:%d: %s", err[1].span.line, err[1].span.col, err[1].message)
end

local show

local function show_list(nodes, separator)
  local parts = {}
  for _, node in ipairs(nodes) do
    parts[#parts + 1] = show(node)
  end
  return table.concat(parts, separator)
end

local function show_block(body)
  return "{ " .. show_list(body, "; ") .. " }"
end

-- Prints a tree compactly, with every operation parenthesized.
show = function(node)
  local kind = node.kind
  if kind == "Int" then
    return string.format("%d", node.value)
  elseif kind == "Float" then
    return string.format("%.17g", node.value)
  elseif kind == "String" then
    return string.format("%q", node.value)
  elseif kind == "Bool" then
    return node.value and "True" or "False"
  elseif kind == "None" then
    return "None"
  elseif kind == "Name" then
    return node.name
  elseif kind == "Specialized" then
    return show(node.callee) .. "[" .. show_list(node.type_args, ", ") .. "]"
  elseif kind == "SpecializedCall" then
    return show(node.callee) .. "[" .. show_list(node.type_args, ", ") .. "](" .. show_list(node.args, ", ") .. ")"
  elseif kind == "CallValue" then
    return "(" .. show(node.callee) .. ")(" .. show_list(node.args, ", ") .. ")"
  elseif kind == "Call" then
    return node.name .. "(" .. show_list(node.args, ", ") .. ")"
  elseif kind == "Unary" then
    return "(" .. node.op .. " " .. show(node.operand) .. ")"
  elseif kind == "Is" then
    return "(" .. show(node.operand) .. " " .. node.op .. " None)"
  elseif kind == "IsInstance" then
    local class = node.class
    return "isinstance(" .. show(node.operand) .. ", " .. (class.module and class.module .. "." or "") .. class.name .. ")"
  elseif kind == "Type" then
    local name = (node.module and node.module .. "." or "") .. node.name
    return node.args and name .. "[" .. show_list(node.args, ", ") .. "]" or name
  elseif kind == "CallableType" then
    return "((" .. show_list(node.params, ", ") .. ") -> " .. show(node.result) .. ")"
  elseif kind == "UnionType" then
    return show_list(node.members, " | ")
  elseif kind == "Alias" then
    return "type " .. node.name .. " = " .. show(node.value)
  elseif kind == "ListDisplay" then
    return "[" .. show_list(node.elements, ", ") .. "]"
  elseif kind == "TupleDisplay" then
    return "tuple(" .. show_list(node.elements, ", ") .. ")"
  elseif kind == "DictDisplay" then
    local parts = {}
    for i, entry in ipairs(node.entries) do
      parts[i] = show(entry.key) .. ": " .. show(entry.value)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  elseif kind == "Index" then
    return show(node.object) .. "[" .. show(node.index) .. "]"
  elseif kind == "Slice" then
    return show(node.object) .. "[" .. (node.start and show(node.start) or "") .. ":"
      .. (node.stop and show(node.stop) or "") .. "]"
  elseif kind == "Keyword" then
    return node.name .. "=" .. show(node.value)
  elseif kind == "MethodCall" then
    return show(node.object) .. "." .. node.name .. "(" .. show_list(node.args, ", ") .. ")"
  elseif kind == "Field" then
    return show(node.object) .. "." .. node.name
  elseif kind == "FString" then
    return "f[" .. show_list(node.parts, ", ") .. "]"
  elseif kind == "FieldAssign" then
    return show(node.object) .. "." .. node.name .. " = " .. show(node.value)
  elseif kind == "Record" then
    local fields = {}
    for i, field in ipairs(node.fields) do
      fields[i] = field.name .. ": " .. show(field.type) .. (field.default and " = " .. show(field.default) or "")
    end
    return "class " .. node.name .. " { " .. table.concat(fields, "; ") .. " }"
  elseif kind == "IndexAssign" then
    return show(node.object) .. "[" .. show(node.index) .. "] = " .. show(node.value)
  elseif kind == "For" then
    return "for " .. (node.name or show(node.pattern)) .. " in " .. show(node.iterable) .. " " .. show_block(node.body)
  elseif kind == "TuplePattern" then
    return "<" .. show_list(node.elements, ", ") .. ">"
  elseif kind == "Unpack" then
    return show(node.pattern) .. " = " .. show(node.value)
  elseif kind == "Binary" then
    return "(" .. show(node.left) .. " " .. node.op .. " " .. show(node.right) .. ")"
  elseif kind == "Param" then
    return (node.keyword_only and "*" or "") .. node.name .. ": " .. show(node.type)
      .. (node.default and " = " .. show(node.default) or "")
  elseif kind == "Function" then
    return "def " .. node.name .. "(" .. show_list(node.params, ", ") .. ") -> "
      .. show(node.return_type) .. " " .. show_block(node.body)
  elseif kind == "Lambda" then
    local names = {}
    for i, param in ipairs(node.params) do
      names[i] = param.name
    end
    return "(lambda " .. table.concat(names, ", ") .. ": " .. show(node.body) .. ")"
  elseif kind == "Nonlocal" then
    local names = {}
    for i, n in ipairs(node.names) do
      names[i] = n.name
    end
    return "nonlocal " .. table.concat(names, ", ")
  elseif kind == "FunctionDef" then
    return show(node.fn)
  elseif kind == "Assign" then
    return node.name .. (node.annotation and ": " .. show(node.annotation) or "") .. " = " .. show(node.value)
  elseif kind == "CallStmt" then
    return show(node.call)
  elseif kind == "Return" then
    return node.value and "return " .. show(node.value) or "return"
  elseif kind == "Pass" or kind == "Break" or kind == "Continue" then
    return kind:lower()
  elseif kind == "If" then
    return "if " .. show(node.condition) .. " " .. show_block(node.body)
      .. (node.else_body and " else " .. show_block(node.else_body) or "")
  elseif kind == "While" then
    return "while " .. show(node.condition) .. " " .. show_block(node.body)
  elseif kind == "Assert" then
    return "assert " .. show(node.condition) .. (node.message and ", " .. show(node.message) or "")
  elseif kind == "Raise" then
    return node.value and "raise " .. show(node.value) or "raise"
  elseif kind == "Try" then
    local text = "try " .. show_block(node.body)
    for _, handler in ipairs(node.handlers) do
      local class = (handler.class.module and handler.class.module .. "." or "") .. handler.class.name
      text = text .. " except " .. class .. (handler.name and " as " .. handler.name or "") .. " " .. show_block(handler.body)
    end
    return text .. (node.finally_body and " finally " .. show_block(node.finally_body) or "")
  end
  error("unknown node kind " .. tostring(kind))
end

-- Wraps statements in `main`, indenting each line one level.
local function in_main(statements)
  return "def main() -> None:\n" .. statements:gsub("[^\n]+", "    %0") .. "\n"
end

local function body(statements)
  return show_block(parse(in_main(statements)).functions[1].body)
end

local function body_error(statements)
  return parse_error(in_main(statements))
end

local function expr(text)
  return show(parse(in_main("x = " .. text)).functions[1].body[1].value)
end

return {
  function_signatures = function()
    local source = "def f() -> None:\n    pass\n\ndef g(a: int, b: bool,\n      c: str, d: None,) -> int:\n    return a\n"
    local program = parse(source)
    eq("def f() -> None { pass }; def g(a: int, b: bool, c: str, d: None) -> int { return a }",
      show_list(program.functions, "; "))
    local g = program.functions[2]
    eq("4:5", g.span.line .. ":" .. g.span.col)
    eq("5:7", g.params[3].span.line .. ":" .. g.params[3].span.col)
    eq("5:28", g.return_type.span.line .. ":" .. g.return_type.span.col)
  end,

  annotations_required_and_limited = function()
    eq("1:8: expected ':', found ')'", parse_error("def f(x) -> int:\n    return x\n"))
    eq("1:14: expected '->', found ':'", parse_error("def f(x: int):\n    pass\n"))
    eq("1:14: expected '[', found ')'", parse_error("def f(x: list) -> None:\n    pass\n"))
    eq("1:10: expected a type, found integer", parse_error("def f(x: 1) -> None:\n    pass\n"))
  end,

  file_scope_holds_only_declarations = function()
    eq("1:1: only function, class, protocol, enum, and type declarations are allowed at file scope", parse_error("x = 1\n"))
    eq("1:1: 'from' is not supported", parse_error("from os import path\n"))
    eq("1:5: only function, class, protocol, enum, and type declarations are allowed at file scope",
      parse_error("    def f() -> None:\n        pass\n"))
  end,

  statements = function()
    local source = table.concat({
      "x = 1",
      "y: int = x + 2",
      "f(x, y)",
      "if x == 1:",
      "    return",
      "while y > 0:",
      "    pass",
      "    break",
      "    continue",
      "return f(y)",
    }, "\n")
    eq("{ x = 1; y: int = (x + 2); f(x, y); if (x == 1) { return }; "
      .. "while (y > 0) { pass; break; continue }; return f(y) }", body(source))
  end,

  if_elif_else_nests = function()
    local source = "if a:\n    pass\nelif b:\n    pass\nelif c:\n    pass\nelse:\n    pass"
    eq("{ if a { pass } else { if b { pass } else { if c { pass } else { pass } } } }", body(source))
    local inner = parse(in_main(source)).functions[1].body[1].else_body[1]
    eq("4:5", inner.span.line .. ":" .. inner.span.col)
  end,

  blocks_need_a_statement = function()
    eq("2:11: expected end of line, found 'pass'", body_error("if a: pass"))
    eq("4:5: expected an indented block, found 'x'", body_error("if a:\n# nothing\nx = 1"))
    eq("2:1: expected an indented block, found end of file", parse_error("def f() -> None:\n"))
  end,

  non_call_expression_statements_rejected = function()
    eq("2:7: only calls can be used as statements", body_error("x + 1"))
    eq("2:5: only calls can be used as statements", body_error("x"))
    eq("2:9: only calls can be used as statements", body_error("f() == 1"))
  end,

  assignment_forms_rejected = function()
    eq("2:11: chained assignment is not supported", body_error("a = b = 1"))
    eq("2:7: unsupported operator '+='", body_error("a += 1"))
    eq("2:9: unsupported operator ':='", body_error("f(a := 1)"))
    eq("2:11: annotated assignment needs an initializer", body_error("x: int"))
    eq("2:9: cannot assign to this expression", body_error("f() = 1"))
  end,

  callable_annotations = function()
    local function annotation(text)
      return show(parse("def f(g: " .. text .. ") -> None:\n    pass\n").functions[1].params[1].type)
    end
    eq("def f(g: ((int, str) -> bool), h: (() -> int)) -> None { pass }",
      show(parse("def f(g: (int, str) -> bool, h: () -> int) -> None:\n    pass\n").functions[1]))
    eq("((int) -> str | None)", annotation("(int) -> str | None"))
    eq("((int) -> str) | None", annotation("((int) -> str) | None"))
    eq("int", annotation("(int)"))
    eq("tuple[(() -> int), int]", annotation("tuple[() -> int, int]"))
    eq("((int) -> ((str) -> bool))", annotation("(int) -> (str) -> bool"))
    eq("((((int) -> int)) -> int)", annotation("((int) -> int) -> int"))
    eq("1:20: expected '->', found ')'", parse_error("def f(g: (int, str)) -> None:\n    pass\n"))
  end,

  keyword_only_parameters = function()
    eq("def f(a: int, *b: int = 1, *c: str) -> None { pass }",
      show(parse("def f(a: int, *, b: int = 1, c: str) -> None:\n    pass\n").functions[1]))
    local record = parse("class C:\n    n: int\n\n    def m(self, *, x: int) -> None:\n        pass\n").records[1]
    eq(true, record.methods[1].params[2].keyword_only)
    eq("1:18: only one '*' is allowed in a parameter list", parse_error("def f(*, a: int, *, b: int) -> None:\n    pass\n"))
    eq("1:8: variadic parameters are not supported", parse_error("def f(*args: int) -> None:\n    pass\n"))
    eq("1:15: '*' must be followed by a keyword-only parameter", parse_error("def f(a: int, *) -> None:\n    pass\n"))
    eq("1:7: '*' must be followed by a keyword-only parameter", parse_error("def f(*) -> None:\n    pass\n"))
    eq("1:19: parameter 'b' without a default follows one with a default",
      parse_error("def f(a: int = 1, b: int, *, c: int) -> None:\n    pass\n"))
  end,

  unpacking = function()
    eq("{ <a, b> = t; <a, <b, c>> = t; <e> = t }", body("a, b = t\n(a, (b, c)) = t\ne, = t"))
    eq("{ for <k, <x, y>> in items { pass } }", body("for k, (x, y) in items:\n    pass"))
    eq("{ for x in items { pass } }", body("for (x) in items:\n    pass"))
    eq("2:8: duplicate target 'a'", body_error("a, a = t"))
    eq("2:16: duplicate target 'k'", body_error("for k, (x, k) in items:\n    pass"))
    eq("2:5: starred targets are not supported", body_error("*a, b = t"))
    eq("2:8: starred targets are not supported", body_error("a, *b = t"))
    eq("2:8: cannot assign to this expression", body_error("a, f() = t"))
    eq("2:13: expected end of line, found ','", body_error("a, b = b, a"))
  end,

  precedence = function()
    eq("(a or (b and (not (c == (d + (e * (- f)))))))", expr("a or b and not c == d + e * -f"))
    eq("((a - b) - c)", expr("a - b - c"))
    eq("((a and b) and c)", expr("a and b and c"))
    eq("((a or b) or c)", expr("a or b or c"))
    eq("(not (a == b))", expr("not a == b"))
    eq("((- a) * b)", expr("-a * b"))
    eq("((a + b) * c)", expr("(a + b) * c"))
    eq("(not (not True))", expr("not not True"))
    eq("((((((a * b) / c) // d) % e) + f) - g)", expr("a * b / c // d % e + f - g"))
  end,

  union_annotations = function()
    local source = "def f(x: int | None) -> str | None:\n    y: bool | None = None\n    return None\n"
    eq("def f(x: int | None) -> str | None { y: bool | None = None; return None }", show(parse(source).functions[1]))
    source = "def f(x: None | int, y: int | str | list[int | float]) -> None:\n    pass\n"
    eq("def f(x: None | int, y: int | str | list[int | float]) -> None { pass }", show(parse(source).functions[1]))
    eq("1:16: expected a type, found ')'", parse_error("def f(x: int | ) -> None:\n    pass\n"))
  end,

  aliases = function()
    local program = parse("import shapes\ntype Json = None | bool | list[Json] | dict[str, Json]\ntype S = shapes.Shape\n")
    eq("type Json = None | bool | list[Json] | dict[str, Json]", show(program.aliases[1]))
    eq("type S = shapes.Shape", show(program.aliases[2]))
    eq("2:6", program.aliases[1].span.line .. ":" .. program.aliases[1].span.col)
    eq("1:7: expected '=', found ':'", parse_error("type T: int\n"))
    eq("2:5: expected a statement, found 'type'", parse_error("def f() -> None:\n    type T = int\n"))
  end,

  tuples = function()
    local fn = parse("def f(x: tuple[int, str | None], y: tuple[()]) -> tuple[int]:\n    pass\n").functions[1]
    eq("def f(x: tuple[int, str | None], y: tuple[]) -> tuple[int] { pass }", show(fn))
    eq(0, #fn.params[2].type.args)
    eq("tuple()", expr("()"))
    eq("tuple(1)", expr("(1,)"))
    eq("tuple(1, (a + b))", expr("(1, a + b,)"))
    eq("1", expr("(1)"))
    eq("isinstance(x, tuple)", expr("isinstance(x, tuple)"))
    eq("2:5: expected a statement, found 'tuple'", body_error("tuple = 1"))
    eq("1:16: expected a type, found ']'", parse_error("def f(x: tuple[]) -> None:\n    pass\n"))
  end,

  isinstance = function()
    eq("isinstance(x, int)", expr("isinstance(x, int)"))
    eq("(isinstance(x, list) and isinstance(y, Point))", expr("isinstance(x, list) and isinstance(y, Point,)"))
    eq("(not isinstance(f(x), shapes.Circle))", expr("not isinstance(f(x), shapes.Circle)"))
    eq("2:23: expected a class name, found 'None'", body_error("x = isinstance(y, None)"))
    eq("2:21: expected ',', found ')'", body_error("x = isinstance(y)"))
    eq("2:27: expected ')', found '['", body_error("x = isinstance(y, list[int])"))
  end,

  is_none = function()
    eq("(x is None)", expr("x is None"))
    eq("(not (x is None))", expr("not x is None"))
    eq("((x is not None) and ((x + 1) is None))", expr("x is not None and x + 1 is None"))
    eq("2:14: expected 'None', found integer", body_error("x = a is 3"))
    eq("2:19: comparison chains are not supported", body_error("x = a is None == b"))
    eq("2:16: comparison chains are not supported", body_error("x = a == b is None"))
    eq("2:11: unsupported operator '|'", body_error("x = a | b"))
    eq("2:16: unsupported operator '|'", body_error("x = a == b | c"))
    eq("2:19: unsupported operator '|'", body_error("x = a is None | b"))
  end,

  collection_annotations = function()
    local source = "def f(x: list[int], y: dict[str, int | None]) -> list[list[str]] | None:\n    return None\n"
    eq("def f(x: list[int], y: dict[str, int | None]) -> list[list[str]] | None { return None }",
      show(parse(source).functions[1]))
  end,

  displays = function()
    eq("[1, [2, 3], []]", expr("[1, [2, 3,], []]"))
    eq('{"a": 1, 2: {}}', expr("{\n    'a': 1,\n    2: {},\n}"))
    eq("2:14: expected ',' or ']', found '}'", body_error("x = [1, 2}"))
  end,

  postfix = function()
    eq("rows[0].pop()", expr("rows[0].pop()"))
    eq("(- xs[0])", expr("-xs[0]"))
    eq("text.strip().split(\",\")", expr("text.strip().split(',')"))
    eq("{ xs[i] = (v + 1); xs.append(2) }", body("xs[i] = v + 1\nxs.append(2)"))
    eq("(items[0])(1)", expr("items[0](1)"))
    eq("(xs.f(1))(2)", expr("xs.f(1)(2)"))
    eq("2:10: only a name can have an annotation", body_error("xs[0]: int = 1"))
    eq("2:7: only calls can be used as statements", body_error("xs[0]"))
  end,

  imports = function()
    local program = parse("import geometry\nimport util\n" .. "def f(p: geometry.Point) -> list[geometry.Point] | None:\n    return None\n")
    eq("geometry util", program.imports[1].name .. " " .. program.imports[2].name)
    local type = program.functions[1].return_type
    eq("list[geometry.Point] | None", show(type))
    local point = type.members[1].args[1]
    eq("geometry Point 3:34", point.module .. " " .. point.name .. " " .. point.span.line .. ":" .. point.span.col)
    eq("3:1: imports must come before declarations", parse_error("def f() -> None:\n    pass\nimport x\n"))
    program = parse("import app.util.text\ndef f(r: app.util.Rec) -> list[app.util.Rec]:\n"
      .. "    try:\n        return [r]\n    except app.errors.Bad:\n        raise\n")
    eq("app.util.text app", program.imports[1].name .. " " .. program.imports[1].root)
    eq("list[app.util.Rec]", show(program.functions[1].return_type))
    eq("app.util Rec", program.functions[1].params[1].type.module .. " " .. program.functions[1].params[1].type.name)
    eq("app.errors", program.functions[1].body[1].handlers[1].class.module)
    eq("isinstance(x, a.b.C)", expr("isinstance(x, a.b.C)"))
    eq("1:10: expected a module name, found end of line", parse_error("import a.\n"))
  end,

  records = function()
    local program = parse("class Node:\n    value: int\n    next: Node | None\n    tags: list[Tag] | None\n")
    eq("class Node { value: int; next: Node | None; tags: list[Tag] | None }", show(program.records[1]))
    local message = "class bodies hold only field and method declarations"
    eq("2:5: " .. message, parse_error("class A:\n    pass\n"))
    eq("2:5: " .. message, parse_error("class A:\n    x = 1\n"))
    eq("3:5: " .. message, parse_error("class A:\n    x: int\n    return\n"))
  end,

  methods = function()
    local program = parse(table.concat({
      "class C:",
      "    n: int",
      "    def get(self) -> int:",
      "        return self.n",
      "    def add(self, k: int = 1) -> None:",
      "        self.n = self.n + k",
      "class Only:",
      "    def f(self,) -> None:",
      "        pass",
      "class E(Exception):",
      "    def show(self) -> str:",
      "        return self.message",
      "",
    }, "\n"))
    local c = program.records[1]
    eq("class C { n: int }", show(c))
    eq("get add", c.methods[1].name .. " " .. c.methods[2].name)
    eq("self k", c.methods[2].params[1].name .. " " .. c.methods[2].params[2].name)
    eq(nil, c.methods[1].params[1].type)
    eq(0, #program.records[2].fields)
    eq(1, #program.records[2].methods[1].params)
    eq("show", program.records[3].methods[1].name)
    eq(0, #program.functions)
    eq("2:11: method 'f' must take 'self' as its first parameter",
      parse_error("class A:\n    def f(x: int) -> None:\n        pass\n"))
    eq("2:11: method 'f' must take 'self' as its first parameter",
      parse_error("class A:\n    def f() -> None:\n        pass\n"))
    eq("2:15: 'self' cannot have an annotation", parse_error("class A:\n    def f(self: A) -> None:\n        pass\n"))
    eq("4:5: fields must come before methods",
      parse_error("class A:\n    def f(self) -> None:\n        pass\n    x: int\n"))
  end,

  exception_classes = function()
    local program = parse("class E(Exception):\n    line: int\nclass F(Exception):\n    pass\n")
    eq("class E { message: str; line: int }", show(program.records[1]))
    eq("class F { message: str }", show(program.records[2]))
    eq(true, program.records[2].exception)
    eq("1:9: the base of a class must be 'Exception'", parse_error("class E(Base):\n    pass\n"))
    eq("2:5: exception class cannot declare field 'message'", parse_error("class E(Exception):\n    message: str\n"))
    eq("2:5: class bodies hold only field and method declarations", parse_error("class E:\n    pass\n"))
    eq("3:5: class bodies hold only field and method declarations", parse_error("class E(Exception):\n    x: int\n    pass\n"))
  end,

  protocols = function()
    local program = parse("protocol P[T]:\n    def read(self, size: int) -> T\n    def close(self) -> None\n")
    local protocol = program.protocols[1]
    eq("P 1 2", protocol.name .. " " .. #protocol.type_params .. " " .. #protocol.methods)
    eq(0, #program.records)
    eq("2:5: protocols hold only method signatures", parse_error("protocol P:\n    x: int\n"))
    eq("2:23: protocol methods have no bodies", parse_error("protocol P:\n    def f(self) -> int:\n        return 1\n"))
    eq("2:11: protocol methods cannot be generic", parse_error("protocol P:\n    def f[T](self, x: T) -> T\n"))
  end,

  raise = function()
    eq("{ raise E(\"x\"); raise }", body("raise E('x')\nraise"))
    eq("2:15: 'raise ... from' is not supported", body_error("raise E() from e"))
  end,

  try = function()
    eq("{ try { f() } except E as e { g(e) } except m.F { pass } finally { h() } }",
      body("try:\n    f()\nexcept E as e:\n    g(e)\nexcept m.F:\n    pass\nfinally:\n    h()"))
    eq("{ try { f() } finally { h() } }", body("try:\n    f()\nfinally:\n    h()"))
    eq("4:1: expected 'except' or 'finally', found dedent", body_error("try:\n    pass"))
    eq("4:5: bare 'except' is not supported", body_error("try:\n    pass\nexcept:\n    pass"))
    eq("4:12: exception class lists are not supported", body_error("try:\n    pass\nexcept (E, F):\n    pass"))
    eq("4:5: 'except*' is not supported", body_error("try:\n    pass\nexcept* E:\n    pass"))
    eq("6:5: 'else' clause on 'try' is not supported",
      body_error("try:\n    pass\nexcept E:\n    pass\nelse:\n    pass"))
  end,

  fields = function()
    eq("a.b.c", expr("a.b.c"))
    eq("rows[0].name", expr("rows[0].name"))
    eq("{ p.x = (p.x + 1) }", body("p.x = p.x + 1"))
    eq("2:8: only a name can have an annotation", body_error("p.x: int = 1"))
  end,

  membership = function()
    eq("((a in b) and (c not in d))", expr("a in b and c not in d"))
    eq("(not (a in b))", expr("not a in b"))
    eq("2:16: comparison chains are not supported", body_error("x = a in b in c"))
    eq("2:16: comparison chains are not supported", body_error("x = a == b not in c"))
  end,

  for_loops = function()
    eq("{ for x in range(1, 3) { print(x) }; for k in d { pass } }",
      body("for x in range(1, 3):\n    print(x)\nfor k in d:\n    pass"))
    eq("2:11: expected 'in', found 'pass'", body_error("for k pass"))
  end,

  f_strings = function()
    eq('f["a", b, "c", (x + 1)]', expr('f"a{b}c{x + 1}"'))
    eq("f[]", expr('f""'))
    eq("2:15: expected an expression, found '}'", body_error("x = f'{1 +}'"))
    eq("2:14: expected '}', found 'b'", body_error("x = f'{a b}'"))
    eq("str(x)", expr("str(x)"))
  end,

  conversions_are_calls = function()
    eq("int(x)", expr("int(x)"))
    eq("(float(1) / 0.5)", expr("float(1) / 0.5"))
    eq("{ x: float = 2.5; float(1) }", body("x: float = 2.5\nfloat(1)"))
    eq("{ x = int }", body("x = int"))
    eq("2:5: cannot assign to 'int'", body_error("int = 1"))
  end,

  binary_span_is_the_operator = function()
    local value = parse(in_main("x = a + b + c")).functions[1].body[1].value
    eq(15, value.span.col)
    eq(11, value.left.span.col)
  end,

  not_needs_parentheses_after_comparison = function()
    eq("2:14: expected an expression, found 'not'", body_error("x = a == not b"))
    eq("(a == (not b))", expr("a == (not b)"))
  end,

  comparison_chains_rejected = function()
    eq("2:16: comparison chains are not supported", body_error("x = 0 <= y < 10"))
    eq("2:16: comparison chains are not supported", body_error("x = a == b == c"))
  end,

  calls_on_values = function()
    eq("{ (f)(x); (f(x))(y) }", body("(f)(x)\nf(x)(y)"))
    eq('{ f(1, g(2), "s") }', body("f(1, g(2), 's',)"))
  end,

  multiline_expressions = function()
    eq("{ f(1, 2); x = (a + b) }", body("f(1,\n  2)\nx = (a +\n        b)"))
  end,

  unclosed_parenthesis_at_end_of_file = function()
    eq("3:1: expected ',' or ')', found end of file", body_error("f(1"))
  end,

  slices_and_keywords = function()
    eq("a[:]", expr("a[:]"))
    eq("a[1:]", expr("a[1:]"))
    eq("a[:(- 1)]", expr("a[:-1]"))
    eq("a[i:j][0]", expr("a[i:j][0]"))
    eq("sorted(xs, reverse=True)", expr("sorted(xs, reverse=True)"))
    eq("2:14: slice steps are not supported", body_error("x = a[1:2:3]"))
    eq("2:12: cannot assign to this expression", body_error("a[1:2] = x"))
  end,

  defaults = function()
    local program = parse("def f(a: int, b: int = -1, c: float = +2.5, d: float = -0.0, e: str = 'x',"
      .. " g: int | None = None, h: bool = True) -> None:\n    pass\n"
      .. "class P:\n    x: int\n    y: int = 0\n")
    eq("def f(a: int, b: int = -1, c: float = 2.5, d: float = -0, e: str = \"x\", g: int | None = None, h: bool = True)"
      .. " -> None { pass }", show(program.functions[1]))
    eq("-inf", tostring(1 / program.functions[1].params[4].default.value))
    eq("class P { x: int; y: int = 0 }", show(program.records[1]))
    eq("def f(a: E = E.A, b: m.E = m.E.B) -> None { pass }",
      show(parse("def f(a: E = E.A, b: m.E = m.E.B) -> None:\n    pass\n").functions[1]))
    eq("def f(a: tuple[] = tuple(), b: tuple[int] = tuple(1), c: tuple[E, int] = tuple(E.A, -1)) -> None { pass }",
      show(parse("def f(a: tuple[()] = (), b: tuple[int] = (1,), c: tuple[E, int] = (E.A, -1)) -> None:\n    pass\n")
        .functions[1]))
    eq("1:18: expected ',', found ')'", parse_error("def f(a: int = (1)) -> None:\n    pass\n"))
    for _, text in ipairs({ "f()", "x", "[1]", "f'a'", "-'a'", "-True", "-E.A" }) do
      eq("1:16: a default must be a literal or an enum member", parse_error("def f(a: int = " .. text .. ") -> None:\n    pass\n"))
    end
    eq("1:19: parameter 'b' without a default follows one with a default",
      parse_error("def f(a: int = 1, b: int) -> None:\n    pass\n"))
    eq("3:5: field 'y' without a default follows one with a default",
      parse_error("class P:\n    x: int = 1\n    y: int\n"))
    eq("2:12: positional argument follows keyword argument", body_error("f(a=1, 2)"))
  end,

  assertions = function()
    eq("{ assert x; assert (x == 1), \"m\" }", body("assert x\nassert x == 1, 'm'"))
    eq("2:11: expected an expression, found end of line", body_error("assert"))
  end,

  generic_functions = function()
    local fn = parse("def f[T, U](x: T) -> U:\n    pass\n").functions[1]
    eq("T U", fn.type_params[1].name .. " " .. fn.type_params[2].name)
    eq("first[int](xs)", expr("first[int](xs)"))
    eq("first[list[int], str | None](xs)", expr("first[list[int], str | None](xs)"))
    eq("util.first[int](xs)", expr("util.first[int](xs)"))
    eq("(xs[0])(1)", expr("xs[0](1)"))
    eq("xs[i]", expr("xs[i]"))
    eq("io.File", show(parse("def f[T: io.File](x: T) -> T:\n    pass\n").functions[1].type_params[1].bound))
    eq("first[int]", expr("first[int]"))
    eq("{ xs[i] = 1 }", body("xs[i] = 1"))
    eq("2:10: unsupported operator '|'", body_error("xs[i | j] = 1"))
    local alias = parse("type Pair[K, V] = tuple[K, V]\n").aliases[1]
    eq("K V", alias.type_params[1].name .. " " .. alias.type_params[2].name)
  end,

  generic_classes = function()
    local record = parse("class Box[T, U]:\n    value: T\n\n    def map[V](self, v: V) -> V:\n        return v\n").records[1]
    eq("T U", record.type_params[1].name .. " " .. record.type_params[2].name)
    eq("V", record.methods[1].type_params[1].name)
  end,

  lambdas_and_nonlocal = function()
    eq("(lambda x, y: (x + y))", expr("lambda x, y: x + y"))
    eq("(lambda : 1)", expr("lambda: 1"))
    eq("(lambda x: x)", expr("lambda x,: x"))
    eq("(lambda x: (lambda : x))", expr("lambda x: lambda: x"))
    eq("f((lambda x: x), 1)", expr("f(lambda x: x, 1)"))
    eq("(lambda x: (x or y))", expr("lambda x: x or y"))
    eq("{ nonlocal a, b }", body("nonlocal a, b"))
    eq("2:17: expected ',' or ':', found '='", body_error("x = lambda a=1: a"))
  end,

  nested_functions = function()
    eq("{ def g(x: int) -> int { return x }; y = g(1) }", body("def g(x: int) -> int:\n    return x\ny = g(1)"))
  end,

  unsupported_reserved_words = function()
    eq("2:5: 'with' is not supported", body_error("with:\n    pass"))
    eq("2:5: 'yield' is not supported", body_error("yield"))
  end,

  enums = function()
    local program = parse("enum Mode:\n    AUTO\n    NEVER\n")
    eq("Mode", program.enums[1].name)
    eq("AUTO NEVER", program.enums[1].members[1].name .. " " .. program.enums[1].members[2].name)
    eq("2:5: enum bodies hold only member names", parse_error("enum Mode:\n    AUTO = 1\n"))
    eq("1:7: expected a parameter name, found 'enum'", parse_error("def f(enum: int) -> None:\n    pass\n"))
  end,
}
