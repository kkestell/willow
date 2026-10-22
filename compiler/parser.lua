-- Parses tokens into the program syntax tree.
local ast = require("compiler.ast")
local diag = require("compiler.diag")
local lexer = require("compiler.lexer")
local span = require("compiler.span")

local M = {}

local set = lexer.set

-- Reserved words with no construct in this slice.
local unsupported = set([[
case del from global match
]])

local compare_ops = set("== != < <= > >= is in")
local type_names = set("int float bool str bytes None list dict tuple Iterable Iterator ContextManager Generator Coroutine")
-- The built-in protocols and `Coroutine`, which take type arguments like a
-- named type.
local protocol_names = set("Iterable Iterator ContextManager Generator Coroutine")
local expression_starts = set("NAME INT FLOAT STRING FSTRING True False None int float str bytes ( [ { - + not await")
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

  -- A member is a `Type` node: a type keyword or a possibly module-qualified
  -- name, with `args` holding a list's element, a dict's key and value, a
  -- tuple's positions, or a named type's arguments. It is also a
  -- `CallableType` with `params` and a `result`, or a parenthesized type.
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

  -- Parses what follows `(`: a callable's parameter list and `-> R`, or a
  -- type the parentheses group. The result extends as far as possible.
  local function parse_parenthesized(open)
    local params = {}
    if not accept(")") then
      params[1] = parse_type()
      if accept(",") then
        for _, param in ipairs(parse_list(")", parse_type)) do
          params[#params + 1] = param
        end
      else
        expect(")")
        if peek().kind ~= "->" then
          return params[1]
        end
      end
    end
    expect("->")
    return ast.node("CallableType", open.span, { params = params, result = parse_type() })
  end

  local function parse_member()
    local token = peek()
    local open = accept("(")
    if open then
      return parse_parenthesized(open)
    end
    if not type_names[token.kind] and token.kind ~= "NAME" then
      unexpected("a type")
    end
    advance()
    local node = ast.node("Type", token.span, { name = token.kind })
    if token.kind == "NAME" or protocol_names[token.kind] then
      if token.kind == "NAME" then
        qualify(node, token.value, "a type name")
      end
      if accept("[") then
        node.args = parse_list("]", parse_type)
      end
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
      -- `tuple[()]` is the empty tuple type; `()` before `->` starts a callable.
      expect("[")
      node.args = {}
      if peek().kind == "(" and tokens[pos + 1].kind == ")" and tokens[pos + 2].kind == "]" then
        advance()
        advance()
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
    elseif kind == "int" or kind == "float" or kind == "str" or kind == "bytes" or kind == "list" then
      -- Conversions are called, or named as values of a callable type.
      advance()
      if accept("(") then
        node = ast.node("Call", token.span, { name = kind, args = parse_args() })
      else
        node = ast.node("Name", token.span, { name = kind, reserved = true })
      end
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

  -- Parses `[...]` after `object` as an index or slice.
  local function parse_index(object)
    local token = advance()
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
      expect("]")
      return ast.node("Slice", token.span, { object = object, start = start, stop = stop })
    end
    expect("]")
    return ast.node("Index", token.span, { object = object, index = start })
  end

  -- Parses `[types]` after a name or field as type arguments, as in
  -- `first[int](xs)` or `first[int]`, or returns nil with the position
  -- unchanged when the brackets can only be an index. Bind decides whether the
  -- callee is generic, so the node keeps the brackets read as an index too, or
  -- the error reading them as one raised.
  local function parse_specialized(callee)
    local saved = pos
    local ok, type_args = pcall(function()
      advance()
      return parse_list("]", parse_type)
    end)
    if not ok then
      pos = saved
      return nil
    end
    local after = pos
    pos = saved
    local indexed, index = pcall(parse_index, callee)
    if not indexed and not diag.is(index) then
      error(index, 0)
    end
    pos = after
    local fields = { callee = callee, type_args = type_args, index = indexed and index or nil,
      index_error = not indexed and index or nil }
    if accept("(") then
      fields.args = parse_args()
      return ast.node("SpecializedCall", callee.span, fields)
    end
    return ast.node("Specialized", callee.span, fields)
  end

  -- Indexing and method calls chain left to right after a primary.
  local function parse_postfix()
    local node = parse_primary()
    while true do
      local token = peek()
      local specialized = token.kind == "[" and (node.kind == "Name" or node.kind == "Field")
        and parse_specialized(node)
      if specialized then
        node = specialized
      elseif token.kind == "[" then
        node = parse_index(node)
      elseif token.kind == "." then
        advance()
        local name = expect("NAME", "a field or method name")
        if accept("(") then
          node = ast.node("MethodCall", name.span, { object = node, name = name.value, args = parse_args() })
        else
          node = ast.node("Field", name.span, { object = node, name = name.value })
        end
      elseif token.kind == "(" then
        advance()
        node = ast.node("CallValue", token.span, { callee = node, args = parse_args() })
      else
        return node
      end
    end
  end

  -- The operand of `await` is a postfix expression, so `await -x` and
  -- `await await c` are errors.
  local function parse_await()
    local token = accept("await")
    if token then
      return ast.node("Await", token.span, { operand = parse_postfix() })
    end
    return parse_postfix()
  end

  local function parse_unary()
    local token = peek()
    if token.kind == "-" or token.kind == "+" then
      advance()
      return ast.node("Unary", token.span, { op = token.kind, operand = parse_unary() })
    end
    return parse_await()
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
  local parse_or = binary_level(set("or"), parse_and)

  -- A lambda binds less tightly than every operator, so its body extends as
  -- far as the enclosing expression allows.
  parse_expression = function()
    local token = peek()
    if not accept("lambda") then
      return parse_or()
    end
    local params = {}
    if not accept(":") then
      repeat
        local name = expect("NAME", "a parameter name")
        params[#params + 1] = ast.node("Param", name.span, { name = name.value })
      until not accept(",") or peek().kind == ":"
      expect(":", "',' or ':'")
    end
    return ast.node("Lambda", token.span, { params = params, body = parse_expression() })
  end

  local parse_block, parse_try, parse_function

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

  local function reject_starred()
    if peek().kind == "*" then
      diag.error(peek().span, "starred targets are not supported")
    end
  end

  -- Reports a target that appears twice in `pattern`, then returns it.
  local function check_targets(pattern, seen)
    if pattern.kind == "Name" then
      if seen[pattern.name] then
        diag.error(pattern.span, "duplicate target '" .. pattern.name .. "'")
      end
      seen[pattern.name] = true
    else
      for _, element in ipairs(pattern.elements) do
        check_targets(element, seen)
      end
    end
    return pattern
  end

  -- The pattern that `expression`, a parsed assignment target, spells.
  local function pattern_of(expression)
    if expression.kind == "Name" and not expression.reserved then
      return expression
    elseif expression.kind == "TupleDisplay" then
      local elements = {}
      for i, element in ipairs(expression.elements) do
        elements[i] = pattern_of(element)
      end
      return ast.node("TuplePattern", expression.span, { elements = elements })
    end
    diag.error(expression.span, "cannot assign to this expression")
  end

  -- A `for` target: a name, or targets in parentheses, where `(a)` is `a`.
  local function parse_target()
    reject_starred()
    local token = peek()
    if accept("(") then
      local first = parse_target()
      if not accept(",") then
        expect(")")
        return first
      end
      local elements = { first }
      for _, element in ipairs(parse_list(")", parse_target)) do
        elements[#elements + 1] = element
      end
      return ast.node("TuplePattern", token.span, { elements = elements })
    end
    local name = expect("NAME", "a loop variable name")
    return ast.node("Name", name.span, { name = name.value })
  end

  local function parse_assignment_or_call()
    reject_starred()
    if not expression_starts[peek().kind] then
      unexpected("a statement")
    end
    local expression = parse_expression()
    local token = peek()
    if expression.kind == "Specialized" and (token.kind == "=" or token.kind == ":") then
      -- Only an index can be assigned to.
      if not expression.index then
        diag.raise(expression.index_error)
      end
      expression = expression.index
    end
    if token.kind == "," then
      -- `a, b = value` assigns to a pattern without parentheses.
      local elements = { expression }
      while accept(",") and peek().kind ~= "=" do
        reject_starred()
        elements[#elements + 1] = parse_expression()
      end
      expression = ast.node("TupleDisplay", expression.span, { elements = elements })
      token = peek()
      if token.kind ~= "=" then
        unexpected("'='")
      end
    end
    if expression.reserved and (token.kind == "=" or token.kind == ":") then
      diag.error(expression.span, "cannot assign to '" .. expression.name .. "'")
    end
    if token.kind == "=" then
      advance()
      local node
      if expression.kind == "TupleDisplay" then
        node = ast.node("Unpack", expression.span,
          { pattern = check_targets(pattern_of(expression), {}), value = parse_expression() })
      elseif expression.kind == "Name" then
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
    elseif expression.kind ~= "Call" and expression.kind ~= "MethodCall" and expression.kind ~= "CallValue"
      and expression.kind ~= "SpecializedCall" and expression.kind ~= "Await" then
      diag.error(expression.span, "only calls and await expressions can be used as statements")
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
      local target = parse_target()
      if peek().kind == "," then
        local elements = { target }
        while accept(",") and peek().kind ~= "in" do
          elements[#elements + 1] = parse_target()
        end
        target = ast.node("TuplePattern", target.span, { elements = elements })
      end
      expect("in")
      local node = ast.node("For", token.span, { iterable = parse_expression() })
      if target.kind == "Name" then
        node.name = target.name
      else
        node.pattern = check_targets(target, {})
      end
      node.body = parse_block()
      return node
    elseif kind == "with" then
      -- Commas separate managers, so a tuple target is parenthesized.
      advance()
      local items, seen = {}, {}
      repeat
        local item = { manager = parse_expression() }
        if accept("as") then
          item.target = check_targets(parse_target(), seen)
        end
        items[#items + 1] = item
      until not accept(",")
      return ast.node("With", token.span, { items = items, body = parse_block() })
    elseif kind == "try" then
      advance()
      return parse_try(token)
    elseif kind == "async" and tokens[pos + 1].kind == "with" then
      -- A task-group scope enters one group and may name it.
      advance()
      advance()
      local node = ast.node("AsyncWith", token.span, { manager = parse_expression() })
      if accept("as") then
        local name = expect("NAME", "a name")
        node.target = ast.node("Name", name.span, { name = name.value })
      end
      node.body = parse_block()
      return node
    elseif kind == "def" or kind == "async" then
      local fn = parse_function()
      return ast.node("FunctionDef", fn.span, { fn = fn, name = fn.name })
    end
    local node
    if kind == "nonlocal" then
      advance()
      local names = {}
      repeat
        local name = expect("NAME", "a variable name")
        names[#names + 1] = { name = name.value, span = name.span }
      until not accept(",")
      node = ast.node("Nonlocal", token.span, { names = names })
    elseif kind == "return" then
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
    elseif kind == "yield" then
      advance()
      node = ast.node("Yield", token.span, { value = parse_expression() })
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

  -- A default is None, a boolean, a string, a number with an optional sign, a
  -- dotted name for an enum member, or a tuple of defaults.
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
    elseif not sign and kind == "(" then
      advance()
      local elements = {}
      if not accept(")") then
        elements[1] = parse_default()
        expect(",", "','")
        for _, element in ipairs(parse_list(")", parse_default)) do
          elements[#elements + 1] = element
        end
      end
      return ast.node("TupleDisplay", token.span, { elements = elements })
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

  -- Parses an optional `[T, U]` after a function or class name.
  local function parse_type_params()
    if not accept("[") then
      return {}
    end
    return parse_list("]", function()
      local param = expect("NAME", "a type parameter name")
      return { name = param.value, span = param.span, bound = accept(":") and parse_type() }
    end)
  end

  -- A method's first parameter is `self`, which has no annotation; bind gives
  -- it the class's type. A `signature` ends at its return type, with no body.
  parse_function = function(method, signature)
    local async = accept("async") ~= nil
    expect("def")
    local name = expect("NAME", "a function name")
    local type_params = parse_type_params()
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
    -- Parameters after a bare `*` are keyword-only, and their defaults may come
    -- in any order.
    local star
    while not closed and not accept(")") do
      if peek().kind == "*" then
        if star then
          diag.error(peek().span, "only one '*' is allowed in a parameter list")
        end
        star = advance()
        if peek().kind == "NAME" then
          diag.error(peek().span, "variadic parameters are not supported")
        end
      else
        local param = expect("NAME", "a parameter name")
        expect(":")
        local node = ast.node("Param", param.span,
          { name = param.value, type = parse_type(), keyword_only = star and true })
        parse_optional_default(node, not star and params[#params] or nil, "parameter")
        params[#params + 1] = node
      end
      if not accept(",") then
        expect(")", "',' or ')'")
        break
      end
    end
    if star and not (params[#params] and params[#params].keyword_only) then
      diag.error(star.span, "'*' must be followed by a keyword-only parameter")
    end
    -- A function without `-> R` returns None.
    local return_type = accept("->") and parse_type() or ast.node("Type", name.span, { name = "None" })
    local body
    if signature then
      if peek().kind == ":" then
        diag.error(peek().span, "protocol methods have no bodies")
      end
      expect("NEWLINE", "end of line")
    else
      body = parse_block()
    end
    return ast.node("Function", name.span, {
      name = name.value, type_params = type_params, params = params, return_type = return_type, body = body,
      async = async,
    })
  end

  -- A protocol holds method signatures, which have no bodies.
  local function parse_protocol()
    advance()
    local name = expect("NAME", "a protocol name")
    local type_params = parse_type_params()
    expect(":")
    expect("NEWLINE", "end of line")
    expect("INDENT", "an indented block")
    local methods = {}
    repeat
      local token = peek()
      if token.kind ~= "def" and token.kind ~= "async" then
        diag.error(token.span, "protocols hold only method signatures")
      end
      local method = parse_function(true, true)
      if #method.type_params > 0 then
        diag.error(method.type_params[1].span, "protocol methods cannot be generic")
      end
      methods[#methods + 1] = method
    until accept("DEDENT")
    return ast.node("Protocol", name.span, { name = name.value, type_params = type_params, methods = methods })
  end

  -- An exception class has `message: str` as its first field and may have a
  -- body of `pass` alone.
  local function parse_record()
    advance()
    local name = expect("NAME", "a class name")
    local type_params = parse_type_params()
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
      return ast.node("Record", name.span,
        { name = name.value, type_params = type_params, fields = fields, methods = {}, exception = true })
    end
    local methods = {}
    repeat
      local field = peek()
      if field.kind == "def" or field.kind == "async" then
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
      { name = name.value, type_params = type_params, fields = fields, methods = methods, exception = exception })
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

  local functions, records, protocols, enums, aliases = {}, {}, {}, {}, {}
  while peek().kind ~= "EOF" do
    local token = peek()
    if token.kind == "import" then
      diag.error(token.span, "imports must come before declarations")
    elseif token.kind == "def" or token.kind == "async" then
      functions[#functions + 1] = parse_function()
    elseif token.kind == "class" then
      records[#records + 1] = parse_record()
    elseif token.kind == "protocol" then
      protocols[#protocols + 1] = parse_protocol()
    elseif token.kind == "enum" then
      enums[#enums + 1] = parse_enum()
    elseif token.kind == "type" then
      advance()
      local name = expect("NAME", "an alias name")
      local type_params = parse_type_params()
      expect("=")
      aliases[#aliases + 1] = ast.node("Alias", name.span,
        { name = name.value, type_params = type_params, value = parse_type() })
      expect("NEWLINE", "end of line")
    else
      reject_unsupported(token)
      diag.error(token.span, "only function, class, protocol, enum, and type declarations are allowed at file scope")
    end
  end
  local path = peek().span.path
  return ast.node("Program", span.new(1, 1, 1, 0, path),
    { imports = imports, functions = functions, records = records, protocols = protocols, enums = enums, aliases = aliases })
end

return M
