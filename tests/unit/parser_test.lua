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
  elseif kind == "Binary" then
    return "(" .. show(node.left) .. " " .. node.op .. " " .. show(node.right) .. ")"
  elseif kind == "Param" then
    return node.name .. ": " .. node.type.name
  elseif kind == "Function" then
    return "def " .. node.name .. "(" .. show_list(node.params, ", ") .. ") -> "
      .. node.return_type.name .. " " .. show_block(node.body)
  elseif kind == "Assign" then
    return node.name .. (node.annotation and ": " .. node.annotation.name or "") .. " = " .. show(node.value)
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
    eq("1:10: expected a type, found 'list'", parse_error("def f(x: list) -> None:\n    pass\n"))
  end,

  file_scope_holds_only_def = function()
    eq("1:1: only function definitions are allowed at file scope", parse_error("x = 1\n"))
    eq("1:1: 'class' is not supported", parse_error("class A:\n    pass\n"))
    eq("1:1: 'import' is not supported", parse_error("import os\n"))
    eq("1:5: only function definitions are allowed at file scope",
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

  unsupported_reserved_words = function()
    eq("2:5: 'for' is not supported", body_error("for x in y:\n    pass"))
    eq("2:5: 'try' is not supported", body_error("try:\n    pass"))
    eq("2:9: 'lambda' is not supported", body_error("x = lambda"))
    eq("2:11: 'is' is not supported", body_error("x = a is b"))
    eq("2:13: 'in' is not supported", body_error("while x in y:\n    pass"))
    eq("2:5: nested functions are not supported", body_error("def g() -> None:\n    pass"))
  end,
}
