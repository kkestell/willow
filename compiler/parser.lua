-- Parses tokens into the program syntax tree.
local ast = require("compiler.ast")
local diag = require("compiler.diag")
local span = require("compiler.span")

local M = {}

local function set(words)
  local result = {}
  for word in words:gmatch("%S+") do
    result[word] = true
  end
  return result
end

-- Reserved words with no construct in this slice.
local unsupported = set([[
as assert async await case class del except finally for from global import in
is lambda match nonlocal raise try type with yield
]])

local compare_ops = set("== != < <= > >=")
local type_names = set("int bool str None")
local expression_starts = set("NAME INT STRING True False None ( - + not")
local simple_statements = { pass = "Pass", ["break"] = "Break", continue = "Continue" }

local descriptions = {
  NEWLINE = "end of line",
  EOF = "end of file",
  INDENT = "indent",
  DEDENT = "dedent",
  INT = "integer",
  STRING = "string",
}

local function describe(token)
  if token.kind == "NAME" then
    return "'" .. token.value .. "'"
  end
  return descriptions[token.kind] or "'" .. token.kind .. "'"
end

local function reject_unsupported(token)
  if unsupported[token.kind] then
    diag.error(token.span, "'" .. token.kind .. "' is not supported")
  end
end

function M.parse(tokens)
  local pos = 1

  local function peek()
    return tokens[pos]
  end

  local function advance()
    local token = tokens[pos]
    pos = pos + 1
    return token
  end

  local function accept(kind)
    if tokens[pos].kind == kind then
      return advance()
    end
  end

  local function unexpected(expected)
    local token = tokens[pos]
    reject_unsupported(token)
    diag.error(token.span, "expected " .. expected .. ", found " .. describe(token))
  end

  local function expect(kind, expected)
    return accept(kind) or unexpected(expected or "'" .. kind .. "'")
  end

  local function parse_type()
    local token = peek()
    if not type_names[token.kind] then
      unexpected("a type")
    end
    advance()
    return ast.node("Type", token.span, { name = token.kind })
  end

  local parse_expression

  local function parse_args()
    local args = {}
    while not accept(")") do
      args[#args + 1] = parse_expression()
      if not accept(",") then
        expect(")", "',' or ')'")
        break
      end
    end
    return args
  end

  local function parse_primary()
    local token = peek()
    local kind = token.kind
    local node
    if kind == "INT" or kind == "STRING" then
      advance()
      node = ast.node(kind == "INT" and "Int" or "String", token.span, { value = token.value })
    elseif kind == "True" or kind == "False" then
      advance()
      node = ast.node("Bool", token.span, { value = kind == "True" })
    elseif kind == "None" then
      advance()
      node = ast.node("None", token.span, {})
    elseif kind == "NAME" then
      advance()
      if accept("(") then
        node = ast.node("Call", token.span, { name = token.value, args = parse_args() })
      else
        node = ast.node("Name", token.span, { name = token.value })
      end
    elseif kind == "(" then
      advance()
      node = parse_expression()
      expect(")")
    else
      unexpected("an expression")
    end
    if peek().kind == "(" then
      diag.error(peek().span, "call target must be a function name")
    end
    return node
  end

  local function parse_unary()
    local token = peek()
    if token.kind == "-" or token.kind == "+" then
      advance()
      return ast.node("Unary", token.span, { op = token.kind, operand = parse_unary() })
    end
    return parse_primary()
  end

  -- Returns a parser for one left-associative binary precedence level.
  local function binary_level(ops, parse_operand)
    return function()
      local left = parse_operand()
      while ops[peek().kind] do
        local token = advance()
        left = ast.node("Binary", token.span, { op = token.kind, left = left, right = parse_operand() })
      end
      return left
    end
  end

  local parse_product = binary_level(set("*"), parse_unary)
  local parse_sum = binary_level(set("+ -"), parse_product)

  -- Comparison operands are sums, so `a == not b` fails and chains are rejected.
  local function parse_comparison()
    local left = parse_sum()
    if not compare_ops[peek().kind] then
      return left
    end
    local token = advance()
    local node = ast.node("Binary", token.span, { op = token.kind, left = left, right = parse_sum() })
    if compare_ops[peek().kind] then
      diag.error(peek().span, "comparison chains are not supported")
    end
    return node
  end

  local function parse_not()
    local token = peek()
    if token.kind == "not" then
      advance()
      return ast.node("Unary", token.span, { op = "not", operand = parse_not() })
    end
    return parse_comparison()
  end

  local parse_and = binary_level(set("and"), parse_not)
  parse_expression = binary_level(set("or"), parse_and)

  local parse_block

  -- Parses the rest of an `if` or `elif` whose keyword `token` was consumed.
  -- An `elif` becomes a nested `If` that is the whole `else_body`.
  local function parse_if(token)
    local condition = parse_expression()
    local body = parse_block()
    local else_body
    local next_token = peek()
    if accept("elif") then
      else_body = { parse_if(next_token) }
    elseif accept("else") then
      else_body = parse_block()
    end
    return ast.node("If", token.span, { condition = condition, body = body, else_body = else_body })
  end

  local function reject_chained_assignment()
    if peek().kind == "=" then
      diag.error(peek().span, "chained assignment is not supported")
    end
  end

  local function parse_assignment_or_call()
    if not expression_starts[peek().kind] then
      unexpected("a statement")
    end
    local expression = parse_expression()
    local token = peek()
    if token.kind == "=" then
      if expression.kind ~= "Name" then
        diag.error(token.span, "cannot assign to this expression")
      end
      advance()
      local node = ast.node("Assign", expression.span, { name = expression.name, value = parse_expression() })
      reject_chained_assignment()
      return node
    elseif token.kind == ":" and expression.kind == "Name" then
      advance()
      local annotation = parse_type()
      if not accept("=") then
        diag.error(peek().span, "annotated assignment needs an initializer")
      end
      local node = ast.node("Assign", expression.span,
        { name = expression.name, annotation = annotation, value = parse_expression() })
      reject_chained_assignment()
      return node
    elseif token.kind == "," and expression.kind == "Name" then
      diag.error(token.span, "destructuring assignment is not supported")
    elseif expression.kind ~= "Call" then
      diag.error(expression.span, "only calls can be used as statements")
    end
    return ast.node("CallStmt", expression.span, { call = expression })
  end

  local function parse_statement()
    local token = peek()
    local kind = token.kind
    if kind == "if" then
      advance()
      return parse_if(token)
    elseif kind == "while" then
      advance()
      local condition = parse_expression()
      return ast.node("While", token.span, { condition = condition, body = parse_block() })
    elseif kind == "def" then
      diag.error(token.span, "nested functions are not supported")
    end
    local node
    if kind == "return" then
      advance()
      local value
      if peek().kind ~= "NEWLINE" then
        value = parse_expression()
      end
      node = ast.node("Return", token.span, { value = value })
    elseif simple_statements[kind] then
      advance()
      node = ast.node(simple_statements[kind], token.span, {})
    else
      node = parse_assignment_or_call()
    end
    expect("NEWLINE", "end of line")
    return node
  end

  parse_block = function()
    expect(":")
    expect("NEWLINE", "end of line")
    expect("INDENT", "an indented block")
    local body = {}
    repeat
      body[#body + 1] = parse_statement()
    until accept("DEDENT")
    return body
  end

  local function parse_function()
    advance()
    local name = expect("NAME", "a function name")
    expect("(")
    local params = {}
    while not accept(")") do
      local param = expect("NAME", "a parameter name")
      expect(":")
      params[#params + 1] = ast.node("Param", param.span, { name = param.value, type = parse_type() })
      if not accept(",") then
        expect(")", "',' or ')'")
        break
      end
    end
    expect("->")
    local return_type = parse_type()
    return ast.node("Function", name.span,
      { name = name.value, params = params, return_type = return_type, body = parse_block() })
  end

  local functions = {}
  while peek().kind ~= "EOF" do
    local token = peek()
    if token.kind ~= "def" then
      reject_unsupported(token)
      diag.error(token.span, "only function definitions are allowed at file scope")
    end
    functions[#functions + 1] = parse_function()
  end
  return ast.node("Program", span.new(1, 1, 1, 0), { functions = functions })
end

return M
