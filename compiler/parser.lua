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
as assert async await case del except finally from global import lambda match
nonlocal raise try type with yield
]])

local compare_ops = set("== != < <= > >= is in")
local type_names = set("int float bool str None list dict")
local expression_starts = set("NAME INT FLOAT STRING FSTRING True False None int float str ( [ { - + not")
local UNIONS = "unions other than 'T | None' are not supported"
local simple_statements = { pass = "Pass", ["break"] = "Break", continue = "Continue" }

local descriptions = {
  NEWLINE = "end of line",
  EOF = "end of file",
  INDENT = "indent",
  DEDENT = "dedent",
  INT = "integer",
  FLOAT = "float",
  STRING = "string",
  FSTRING = "f-string",
  FIELD_END = "'}'",
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

  -- A type's `records` lists the record names it mentions, for bind to check.
  local function parse_type()
    local token = peek()
    if not type_names[token.kind] and token.kind ~= "NAME" then
      unexpected("a type")
    end
    advance()
    local name = token.kind
    local records = {}
    local function inner()
      local node = parse_type()
      for _, record in ipairs(node.records) do
        records[#records + 1] = record
      end
      return node
    end
    if name == "NAME" then
      name = token.value
      records[1] = { name = name, span = token.span }
    elseif name == "list" then
      expect("[")
      name = "list[" .. inner().name .. "]"
      expect("]")
    elseif name == "dict" then
      expect("[")
      local key = inner()
      if key.name ~= "int" and key.name ~= "str" then
        diag.error(key.span, "dictionary keys must be int or str")
      end
      expect(",")
      name = "dict[" .. key.name .. ", " .. inner().name .. "]"
      expect("]")
    end
    if token.kind ~= "None" and accept("|") then
      if peek().kind ~= "None" then
        diag.error(peek().span, UNIONS)
      end
      advance()
      name = name .. " | None"
    end
    if peek().kind == "|" then
      diag.error(peek().span, UNIONS)
    end
    return ast.node("Type", token.span, { name = name, records = records })
  end

  local parse_expression

  -- Parses comma-separated items up to `close`, allowing a trailing comma.
  local function parse_list(close, parse_item)
    local items = {}
    while not accept(close) do
      items[#items + 1] = parse_item()
      if not accept(",") then
        expect(close, "',' or '" .. close .. "'")
        break
      end
    end
    return items
  end

  local function parse_args()
    return parse_list(")", parse_expression)
  end

  local function parse_entry()
    local key = parse_expression()
    expect(":")
    return { key = key, value = parse_expression() }
  end

  local function parse_primary()
    local token = peek()
    local kind = token.kind
    local node
    if kind == "INT" or kind == "STRING" then
      advance()
      node = ast.node(kind == "INT" and "Int" or "String", token.span, { value = token.value })
    elseif kind == "FLOAT" then
      advance()
      node = ast.node("Float", token.span, { value = token.value })
    elseif kind == "FSTRING" then
      advance()
      local parts = {}
      for _, part in ipairs(token.value) do
        if type(part) == "table" then
          -- Each field is its own token list ending in FIELD_END.
          local outer_tokens, outer_pos = tokens, pos
          tokens, pos = part, 1
          parts[#parts + 1] = parse_expression()
          expect("FIELD_END", "'}'")
          tokens, pos = outer_tokens, outer_pos
        elseif part ~= "" then
          parts[#parts + 1] = ast.node("String", token.span, { value = part })
        end
      end
      node = ast.node("FString", token.span, { parts = parts })
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
    elseif (kind == "int" or kind == "float" or kind == "str") and tokens[pos + 1].kind == "(" then
      advance()
      advance()
      node = ast.node("Call", token.span, { name = kind, args = parse_args() })
    elseif kind == "(" then
      advance()
      node = parse_expression()
      expect(")")
    elseif kind == "[" then
      advance()
      node = ast.node("ListDisplay", token.span, { elements = parse_list("]", parse_expression) })
    elseif kind == "{" then
      advance()
      node = ast.node("DictDisplay", token.span, { entries = parse_list("}", parse_entry) })
    else
      unexpected("an expression")
    end
    return node
  end

  -- Indexing and method calls chain left to right after a primary.
  local function parse_postfix()
    local node = parse_primary()
    while true do
      local token = peek()
      if token.kind == "[" then
        advance()
        node = ast.node("Index", token.span, { object = node, index = parse_expression() })
        expect("]")
      elseif token.kind == "." then
        advance()
        local name = expect("NAME", "a field or method name")
        if accept("(") then
          node = ast.node("MethodCall", name.span, { object = node, name = name.value, args = parse_args() })
        else
          node = ast.node("Field", name.span, { object = node, name = name.value })
        end
      elseif token.kind == "(" then
        diag.error(token.span, "call target must be a function name")
      else
        return node
      end
    end
  end

  local function parse_unary()
    local token = peek()
    if token.kind == "-" or token.kind == "+" then
      advance()
      return ast.node("Unary", token.span, { op = token.kind, operand = parse_unary() })
    end
    return parse_postfix()
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

  local parse_product = binary_level(set("* / // %"), parse_unary)
  local parse_sum = binary_level(set("+ -"), parse_product)

  -- An expression before `|` ends at a comparison operand, so this is where
  -- bitwise or is reported.
  local function reject_bitwise_or()
    if peek().kind == "|" then
      diag.error(peek().span, "unsupported operator '|'")
    end
  end

  local function parse_operand()
    local node = parse_sum()
    reject_bitwise_or()
    return node
  end

  -- Comparison operands are sums, so `a == not b` fails and chains are rejected.
  local function parse_comparison()
    local left = parse_operand()
    local negated_in = peek().kind == "not" and tokens[pos + 1].kind == "in"
    if not compare_ops[peek().kind] and not negated_in then
      return left
    end
    local token = advance()
    local node
    if negated_in then
      advance()
      node = ast.node("Binary", token.span, { op = "not in", left = left, right = parse_operand() })
    elseif token.kind == "is" then
      local op = accept("not") and "is not" or "is"
      expect("None", "'None'")
      reject_bitwise_or()
      node = ast.node("Is", token.span, { op = op, operand = left })
    else
      node = ast.node("Binary", token.span, { op = token.kind, left = left, right = parse_operand() })
    end
    if compare_ops[peek().kind] or peek().kind == "not" and tokens[pos + 1].kind == "in" then
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
      advance()
      local node
      if expression.kind == "Name" then
        node = ast.node("Assign", expression.span, { name = expression.name, value = parse_expression() })
      elseif expression.kind == "Index" then
        node = ast.node("IndexAssign", expression.span,
          { object = expression.object, index = expression.index, value = parse_expression() })
      elseif expression.kind == "Field" then
        node = ast.node("FieldAssign", expression.span,
          { object = expression.object, name = expression.name, value = parse_expression() })
      else
        diag.error(token.span, "cannot assign to this expression")
      end
      reject_chained_assignment()
      return node
    elseif token.kind == ":" and (expression.kind == "Index" or expression.kind == "Field") then
      diag.error(token.span, "only a name can have an annotation")
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
    elseif expression.kind ~= "Call" and expression.kind ~= "MethodCall" then
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
    elseif kind == "for" then
      advance()
      local name = expect("NAME", "a loop variable name")
      expect("in")
      local iterable = parse_expression()
      return ast.node("For", token.span, { name = name.value, iterable = iterable, body = parse_block() })
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

  local function parse_record()
    advance()
    local name = expect("NAME", "a record name")
    expect(":")
    expect("NEWLINE", "end of line")
    expect("INDENT", "an indented block")
    local fields = {}
    repeat
      local field = peek()
      if field.kind ~= "NAME" or tokens[pos + 1].kind ~= ":" then
        diag.error(field.span, "record bodies hold only field declarations")
      end
      advance()
      advance()
      fields[#fields + 1] = ast.node("FieldDecl", field.span, { name = field.value, type = parse_type() })
      expect("NEWLINE", "end of line")
    until accept("DEDENT")
    return ast.node("Record", name.span, { name = name.value, fields = fields })
  end

  local functions, records = {}, {}
  while peek().kind ~= "EOF" do
    local token = peek()
    if token.kind == "def" then
      functions[#functions + 1] = parse_function()
    elseif token.kind == "class" then
      records[#records + 1] = parse_record()
    else
      reject_unsupported(token)
      diag.error(token.span, "only function and class definitions are allowed at file scope")
    end
  end
  return ast.node("Program", span.new(1, 1, 1, 0), { functions = functions, records = records })
end

return M
