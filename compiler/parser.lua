-- Parses tokens into the program syntax tree.
local ast = require("compiler.ast")
local diag = require("compiler.diag")
local lexer = require("compiler.lexer")
local span = require("compiler.span")

local M = {}

local set = lexer.set

-- Reserved words with no construct in this slice.
local unsupported = set([[
async await case del from global lambda match nonlocal with yield
]])

local compare_ops = set("== != < <= > >= is in")
local type_names = set("int float bool str bytes None list dict tuple")
local expression_starts = set("NAME INT FLOAT STRING FSTRING True False None int float str bytes ( [ { - + not")
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

  -- A member is a `Type` node: a type keyword or a possibly module-qualified
  -- name, with `args` holding a list's element or a dict's key and value.
  local parse_type

  -- Reads `. NAME` parts after `first`, a NAME already consumed, into `ref`:
  -- the last name is `ref.name` and any before it, joined by `.`, `ref.module`.
  local function qualify(ref, first, what)
    local names = { first }
    while accept(".") do
      names[#names + 1] = expect("NAME", what).value
    end
    ref.name = names[#names]
    if #names > 1 then
      ref.module = table.concat(names, ".", 1, #names - 1)
    end
    return ref
  end

  local function parse_member()
    local token = peek()
    if not type_names[token.kind] and token.kind ~= "NAME" then
      unexpected("a type")
    end
    advance()
    local node = ast.node("Type", token.span, { name = token.kind })
    if token.kind == "NAME" then
      qualify(node, token.value, "a type name")
    elseif token.kind == "list" then
      expect("[")
      node.args = { parse_type() }
      expect("]")
    elseif token.kind == "dict" then
      expect("[")
      local key = parse_type()
      expect(",")
      node.args = { key, parse_type() }
      expect("]")
    elseif token.kind == "tuple" then
      -- `tuple[()]` is the empty tuple type.
      expect("[")
      node.args = {}
      if accept("(") then
        expect(")")
      else
        repeat
          node.args[#node.args + 1] = parse_type()
        until not accept(",")
      end
      expect("]")
    end
    return node
  end

  parse_type = function()
    local first = parse_member()
    if peek().kind ~= "|" then
      return first
    end
    local members = { first }
    while accept("|") do
      members[#members + 1] = parse_member()
    end
    return ast.node("UnionType", first.span, { members = members })
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

  -- An argument is an expression or a `Keyword` node for `name=expression`.
  local function parse_arg()
    if peek().kind == "NAME" and tokens[pos + 1].kind == "=" then
      local name = advance()
      advance()
      return ast.node("Keyword", name.span, { name = name.value, value = parse_expression() })
    end
    return parse_expression()
  end

  local function parse_args()
    local args = parse_list(")", parse_arg)
    for i = 2, #args do
      if args[i].kind ~= "Keyword" and args[i - 1].kind == "Keyword" then
        diag.error(args[i].span, "positional argument follows keyword argument")
      end
    end
    return args
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
      local parts, specs = {}, {}
      for _, part in ipairs(token.value) do
        if type(part) == "table" then
          -- Each field is its own token list ending in FIELD_END.
          local outer_tokens, outer_pos = tokens, pos
          tokens, pos = part, 1
          parts[#parts + 1] = parse_expression()
          specs[#parts] = part.spec
          expect("FIELD_END", "'}'")
          tokens, pos = outer_tokens, outer_pos
        elseif part ~= "" then
          parts[#parts + 1] = ast.node("String", token.span, { value = part })
        end
      end
      node = ast.node("FString", token.span, { parts = parts, specs = specs })
    elseif kind == "True" or kind == "False" then
      advance()
      node = ast.node("Bool", token.span, { value = kind == "True" })
    elseif kind == "None" then
      advance()
      node = ast.node("None", token.span, {})
    elseif kind == "NAME" and token.value == "isinstance" and tokens[pos + 1].kind == "(" then
      advance()
      advance()
      local operand = parse_expression()
      expect(",", "','")
      local name = peek()
      if name.kind ~= "NAME" and (name.kind == "None" or not type_names[name.kind]) then
        unexpected("a class name")
      end
      advance()
      local class = { name = name.kind == "NAME" and name.value or name.kind, span = name.span }
      if name.kind == "NAME" then
        qualify(class, name.value, "a class name")
      end
      accept(",")
      expect(")", "')'")
      node = ast.node("IsInstance", token.span, { operand = operand, class = class })
    elseif kind == "NAME" then
      advance()
      if accept("(") then
        node = ast.node("Call", token.span, { name = token.value, args = parse_args() })
      else
        node = ast.node("Name", token.span, { name = token.value })
      end
    elseif (kind == "int" or kind == "float" or kind == "str" or kind == "bytes") and tokens[pos + 1].kind == "(" then
      advance()
      advance()
      node = ast.node("Call", token.span, { name = kind, args = parse_args() })
    elseif kind == "(" then
      -- `(x)` is grouping; a comma or empty parentheses make a tuple.
      advance()
      if accept(")") then
        node = ast.node("TupleDisplay", token.span, { elements = {} })
      else
        node = parse_expression()
        if accept(",") then
          local elements = { node }
          for _, element in ipairs(parse_list(")", parse_expression)) do
            elements[#elements + 1] = element
          end
          node = ast.node("TupleDisplay", token.span, { elements = elements })
        else
          expect(")")
        end
      end
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
        local start, stop
        if peek().kind ~= ":" then
          start = parse_expression()
        end
        if accept(":") then
          if peek().kind ~= "]" and peek().kind ~= ":" then
            stop = parse_expression()
          end
          if peek().kind == ":" then
            diag.error(peek().span, "slice steps are not supported")
          end
          node = ast.node("Slice", token.span, { object = node, start = start, stop = stop })
        else
          node = ast.node("Index", token.span, { object = node, index = start })
        end
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

  local parse_block, parse_try

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

  -- Parses the clauses of a `try` whose keyword `token` was consumed.
  parse_try = function(token)
    local body = parse_block()
    local handlers = {}
    while peek().kind == "except" do
      local clause = advance()
      local next_token = peek()
      if next_token.kind == ":" then
        diag.error(clause.span, "bare 'except' is not supported")
      elseif next_token.kind == "(" then
        diag.error(next_token.span, "exception class lists are not supported")
      elseif next_token.kind == "*" then
        diag.error(clause.span, "'except*' is not supported")
      end
      local name = expect("NAME", "an exception class name")
      local class = qualify({ span = name.span }, name.value, "an exception class name")
      local bound
      if accept("as") then
        bound = expect("NAME", "a name").value
      end
      handlers[#handlers + 1] = { class = class, name = bound, body = parse_block(), span = clause.span }
    end
    local finally_body
    if accept("finally") then
      finally_body = parse_block()
    end
    if peek().kind == "else" then
      diag.error(peek().span, "'else' clause on 'try' is not supported")
    end
    if #handlers == 0 and not finally_body then
      unexpected("'except' or 'finally'")
    end
    return ast.node("Try", token.span, { body = body, handlers = handlers, finally_body = finally_body })
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
    elseif kind == "try" then
      advance()
      return parse_try(token)
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
    elseif kind == "assert" then
      advance()
      local condition = parse_expression()
      local message = accept(",") and parse_expression() or nil
      node = ast.node("Assert", token.span, { condition = condition, message = message })
    elseif kind == "raise" then
      advance()
      local value
      if peek().kind ~= "NEWLINE" then
        value = parse_expression()
        if peek().kind == "from" then
          diag.error(peek().span, "'raise ... from' is not supported")
        end
      end
      node = ast.node("Raise", token.span, { value = value })
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

  -- A default is None, a boolean, a string, a number with an optional sign, or
  -- a dotted name for an enum member.
  local function parse_default()
    local token = peek()
    local sign = (token.kind == "-" or token.kind == "+") and advance().kind
    local literal = peek()
    local kind = literal.kind
    if kind == "INT" or kind == "FLOAT" then
      advance()
      local value = literal.value
      if sign == "-" then
        value = kind == "INT" and 0 - value or -value
      end
      return ast.node(kind == "INT" and "Int" or "Float", token.span, { value = value })
    elseif not sign and kind == "STRING" then
      advance()
      return ast.node("String", token.span, { value = literal.value })
    elseif not sign and (kind == "True" or kind == "False") then
      advance()
      return ast.node("Bool", token.span, { value = kind == "True" })
    elseif not sign and kind == "None" then
      advance()
      return ast.node("None", token.span, {})
    elseif not sign and kind == "NAME" and tokens[pos + 1].kind == "." then
      local node = ast.node("Name", token.span, { name = advance().value })
      while accept(".") do
        local name = expect("NAME", "a member name")
        node = ast.node("Field", name.span, { object = node, name = name.value })
      end
      return node
    end
    diag.error(token.span, "a default must be a literal or an enum member")
  end

  -- Parses `= default` after the type of `decl`, a parameter or field, which
  -- must have one when `previous` does.
  local function parse_optional_default(decl, previous, noun)
    if accept("=") then
      decl.default = parse_default()
    elseif previous and previous.default then
      diag.error(decl.span, noun .. " '" .. decl.name .. "' without a default follows one with a default")
    end
  end

  -- A method's first parameter is `self`, which has no annotation; bind gives
  -- it the class's type.
  local function parse_function(method)
    advance()
    local name = expect("NAME", "a function name")
    expect("(")
    local params, closed = {}, false
    if method then
      local self = peek()
      if self.kind ~= "NAME" or self.value ~= "self" then
        diag.error(self.span, "method '" .. name.value .. "' must take 'self' as its first parameter")
      end
      advance()
      if peek().kind == ":" then
        diag.error(peek().span, "'self' cannot have an annotation")
      end
      params[1] = ast.node("Param", self.span, { name = "self" })
      closed = not accept(",")
      if closed then
        expect(")", "',' or ')'")
      end
    end
    while not closed and not accept(")") do
      local param = expect("NAME", "a parameter name")
      expect(":")
      local node = ast.node("Param", param.span, { name = param.value, type = parse_type() })
      parse_optional_default(node, params[#params], "parameter")
      params[#params + 1] = node
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

  -- An exception class has `message: str` as its first field and may have a
  -- body of `pass` alone.
  local function parse_record()
    advance()
    local name = expect("NAME", "a class name")
    local exception = false
    local fields = {}
    if accept("(") then
      local base = expect("NAME", "a base class name")
      if base.value ~= "Exception" then
        diag.error(base.span, "the base of a class must be 'Exception'")
      end
      expect(")")
      exception = true
      fields[1] = ast.node("FieldDecl", name.span,
        { name = "message", type = ast.node("Type", name.span, { name = "str" }) })
    end
    expect(":")
    expect("NEWLINE", "end of line")
    expect("INDENT", "an indented block")
    if exception and accept("pass") then
      expect("NEWLINE", "end of line")
      expect("DEDENT", "the end of the class")
      return ast.node("Record", name.span, { name = name.value, fields = fields, methods = {}, exception = true })
    end
    local methods = {}
    repeat
      local field = peek()
      if field.kind == "def" then
        methods[#methods + 1] = parse_function(true)
      else
        if field.kind ~= "NAME" or tokens[pos + 1].kind ~= ":" then
          diag.error(field.span, "class bodies hold only field and method declarations")
        elseif #methods > 0 then
          diag.error(field.span, "fields must come before methods")
        end
        if exception and field.value == "message" then
          diag.error(field.span, "exception class cannot declare field 'message'")
        end
        advance()
        advance()
        local node = ast.node("FieldDecl", field.span, { name = field.value, type = parse_type() })
        parse_optional_default(node, fields[#fields], "field")
        fields[#fields + 1] = node
        expect("NEWLINE", "end of line")
      end
    until accept("DEDENT")
    return ast.node("Record", name.span,
      { name = name.value, fields = fields, methods = methods, exception = exception })
  end

  local function parse_enum()
    advance()
    local name = expect("NAME", "an enum name")
    expect(":")
    expect("NEWLINE", "end of line")
    expect("INDENT", "an indented block")
    local members = {}
    repeat
      local member = peek()
      if member.kind ~= "NAME" or tokens[pos + 1].kind ~= "NEWLINE" then
        diag.error(member.span, "enum bodies hold only member names")
      end
      advance()
      advance()
      members[#members + 1] = { name = member.value, span = member.span }
    until accept("DEDENT")
    return ast.node("Enum", name.span, { name = name.value, members = members })
  end

  local imports = {}
  while peek().kind == "import" do
    advance()
    local name = expect("NAME", "a module name")
    local names = { name.value }
    while accept(".") do
      names[#names + 1] = expect("NAME", "a module name").value
    end
    expect("NEWLINE", "end of line")
    imports[#imports + 1] = { name = table.concat(names, "."), root = name.value, span = name.span }
  end

  local functions, records, enums, aliases = {}, {}, {}, {}
  while peek().kind ~= "EOF" do
    local token = peek()
    if token.kind == "import" then
      diag.error(token.span, "imports must come before declarations")
    elseif token.kind == "def" then
      functions[#functions + 1] = parse_function()
    elseif token.kind == "class" then
      records[#records + 1] = parse_record()
    elseif token.kind == "enum" then
      enums[#enums + 1] = parse_enum()
    elseif token.kind == "type" then
      advance()
      local name = expect("NAME", "an alias name")
      expect("=")
      aliases[#aliases + 1] = ast.node("Alias", name.span, { name = name.value, value = parse_type() })
      expect("NEWLINE", "end of line")
    else
      reject_unsupported(token)
      diag.error(token.span, "only function, class, enum, and type declarations are allowed at file scope")
    end
  end
  local path = peek().span.path
  return ast.node("Program", span.new(1, 1, 1, 0, path),
    { imports = imports, functions = functions, records = records, enums = enums, aliases = aliases })
end

return M
