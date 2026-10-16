local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local diag = require("compiler.diag")

local function eq(expected, actual)
  if expected ~= actual then
    error(string.format("expected %q, got %q", tostring(expected), tostring(actual)), 2)
  end
end

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
  elseif kind == "UnionType" then
    return show_list(node.members, " | ")
  elseif kind == "Alias" then
    return "type " .. node.name .. " = " .. show(node.value)
  elseif kind == "ListDisplay" then
    return "[" .. show_list(node.elements, ", ") .. "]"
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
      fields[i] = field.name .. ": " .. show(field.type)
    end
    return "class " .. node.name .. " { " .. table.concat(fields, "; ") .. " }"
  elseif kind == "IndexAssign" then
    return show(node.object) .. "[" .. show(node.index) .. "] = " .. show(node.value)
  elseif kind == "For" then
    return "for " .. node.name .. " in " .. show(node.iterable) .. " " .. show_block(node.body)
  elseif kind == "Binary" then
    return "(" .. show(node.left) .. " " .. node.op .. " " .. show(node.right) .. ")"
  elseif kind == "Param" then
    return node.name .. ": " .. show(node.type)
  elseif kind == "Function" then
    return "def " .. node.name .. "(" .. show_list(node.params, ", ") .. ") -> "
      .. show(node.return_type) .. " " .. show_block(node.body)
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
    eq("1:1: only function, class, and type declarations are allowed at file scope", parse_error("x = 1\n"))
    eq("1:1: 'from' is not supported", parse_error("from os import path\n"))
    eq("1:5: only function, class, and type declarations are allowed at file scope",
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
    eq("2:6: destructuring assignment is not supported", body_error("a, b = 1, 2"))
    eq("2:7: unsupported operator '+='", body_error("a += 1"))
    eq("2:9: unsupported operator ':='", body_error("f(a := 1)"))
    eq("2:11: annotated assignment needs an initializer", body_error("x: int"))
    eq("2:9: cannot assign to this expression", body_error("f() = 1"))
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
    eq("2:17: call target must be a function name", body_error("x = items[0](1)"))
    eq("2:16: call target must be a function name", body_error("x = xs.f(1)(2)"))
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
    eq("1:9: expected end of line, found '.'", parse_error("import a.b\n"))
  end,

  records = function()
    local program = parse("class Node:\n    value: int\n    next: Node | None\n    tags: list[Tag] | None\n")
    eq("class Node { value: int; next: Node | None; tags: list[Tag] | None }", show(program.records[1]))
    local message = "record bodies hold only field declarations"
    eq("2:5: " .. message, parse_error("class A:\n    pass\n"))
    eq("2:5: " .. message, parse_error("class A:\n    x = 1\n"))
    eq("3:5: " .. message, parse_error("class A:\n    x: int\n    def f() -> None:\n        pass\n"))
  end,

  exception_classes = function()
    local program = parse("class E(Exception):\n    line: int\nclass F(Exception):\n    pass\n")
    eq("class E { message: str; line: int }", show(program.records[1]))
    eq("class F { message: str }", show(program.records[2]))
    eq(true, program.records[2].exception)
    eq("1:9: the base of a class must be 'Exception'", parse_error("class E(Base):\n    pass\n"))
    eq("2:5: exception class cannot declare field 'message'", parse_error("class E(Exception):\n    message: str\n"))
    eq("2:5: record bodies hold only field declarations", parse_error("class E:\n    pass\n"))
    eq("3:5: record bodies hold only field declarations", parse_error("class E(Exception):\n    x: int\n    pass\n"))
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
    eq("2:10: expected 'in', found ','", body_error("for k, v in d:\n    pass"))
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
    eq("2:9: expected an expression, found 'int'", body_error("x = int"))
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

  call_targets_are_names = function()
    eq("2:8: call target must be a function name", body_error("(f)(x)"))
    eq("2:9: call target must be a function name", body_error("f(x)(y)"))
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

  unsupported_reserved_words = function()
    eq("2:5: 'with' is not supported", body_error("with:\n    pass"))
    eq("2:9: 'lambda' is not supported", body_error("x = lambda"))
    eq("2:5: nested functions are not supported", body_error("def g() -> None:\n    pass"))
  end,
}
