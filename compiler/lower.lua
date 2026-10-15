-- Lowers the checked tree into explicit evaluation order and control flow.
local M = {}

local helpers = { ["+"] = "add", ["-"] = "sub", ["*"] = "mul" }

-- True when evaluating `node` can neither call anything nor fail, so it can be
-- evaluated wherever its value is used. Callees cannot change a caller's
-- locals, so a later call cannot change its value either.
local function is_pure(node)
  local kind = node.kind
  if kind == "Call" then
    return false
  elseif kind == "Unary" then
    return node.op ~= "-" and is_pure(node.operand)
  elseif kind == "Binary" then
    -- A binary operation of type int is checked arithmetic.
    return node.type ~= "int" and is_pure(node.left) and is_pure(node.right)
  end
  return true
end

local function lower_function(fn, sites)
  local out
  local depth, temps, labels = 0, 0, 0
  local loop

  local function emit(statement)
    out[#out + 1] = statement
  end

  -- A statement's span is its call or helper's span when it has one.
  local function set(target, value, span)
    emit({ kind = "Set", target = target, value = value, span = value.span or span })
  end

  local function push_temp()
    depth = depth + 1
    temps = math.max(temps, depth)
    return { kind = "Temp", index = depth }
  end

  local function helper(name, args, span)
    sites[#sites + 1] = span
    return { kind = "Helper", name = name, args = args, site = #sites, span = span }
  end

  local lower_value, lower_operand

  -- `a and b` or `a or b` whose right operand needs statements: the right
  -- operand runs only in the branch that needs it.
  local function lower_short_circuit(node)
    local mark = depth
    local left = lower_operand(node.left)
    depth = mark
    local result = push_temp()
    if not (left.kind == "Temp" and left.index == result.index) then
      set(result, left, node.span)
    end
    local outer = out
    out = {}
    set(result, lower_value(node.right), node.span)
    local body = out
    out = outer
    depth = mark + 1
    local condition = node.op == "and" and result or { kind = "Not", operand = result }
    emit({ kind = "If", condition = condition, body = body, span = node.span })
    return result
  end

  -- Returns an expression whose operands contain no calls; the expression
  -- itself may be one call or helper call.
  lower_value = function(node)
    local kind = node.kind
    if kind == "Int" or kind == "String" or kind == "Bool" then
      return { kind = "Literal", value = node.value }
    elseif kind == "None" then
      return { kind = "Literal" }
    elseif kind == "Name" then
      return { kind = "Local", symbol = node.symbol }
    elseif kind == "Unary" then
      if node.op == "+" then
        return lower_value(node.operand)
      end
      local operand = lower_operand(node.operand)
      if node.op == "not" then
        return { kind = "Not", operand = operand }
      end
      return helper("neg", { operand }, node.span)
    elseif kind == "Binary" then
      if (node.op == "and" or node.op == "or") and not is_pure(node.right) then
        return lower_short_circuit(node)
      end
      local left = lower_operand(node.left)
      local right = lower_operand(node.right)
      if node.type == "int" then
        return helper(helpers[node.op], { left, right }, node.span)
      end
      local op = node.op == "+" and "concat" or node.op
      return { kind = "Binary", op = op, left = left, right = right }
    elseif kind == "Call" then
      local args = {}
      for i, arg in ipairs(node.args) do
        args[i] = lower_operand(arg)
      end
      if node.target.kind == "Builtin" then
        return helper("print", args, node.span)
      end
      return { kind = "Call", target = node.target, args = args, span = node.span }
    end
  end

  -- Returns an expression with no calls, moving a call or helper call into a
  -- temporary first.
  lower_operand = function(node)
    local mark = depth
    local value = lower_value(node)
    if value.kind ~= "Call" and value.kind ~= "Helper" then
      return value
    end
    -- The call consumes its operands' temporaries, so its result reuses them.
    depth = mark
    local temp = push_temp()
    set(temp, value)
    return temp
  end

  local lower_block

  local function lower_statement(statement)
    depth = 0
    local kind = statement.kind
    if kind == "Assign" then
      set({ kind = "Local", symbol = statement.symbol }, lower_value(statement.value), statement.span)
    elseif kind == "CallStmt" then
      local value = lower_value(statement.call)
      emit({ kind = "Eval", value = value, span = value.span })
    elseif kind == "Return" then
      -- A returned value never contains a call, so no return is a tail call.
      local value = statement.value and lower_operand(statement.value)
      emit({ kind = "Return", value = value, span = statement.span })
    elseif kind == "If" then
      local condition = lower_operand(statement.condition)
      local body = lower_block(statement.body)
      local else_body = statement.else_body and lower_block(statement.else_body)
      emit({ kind = "If", condition = condition, body = body, else_body = else_body, span = statement.span })
    elseif kind == "While" then
      labels = labels + 1
      local node = { kind = "While", label = labels, span = statement.span }
      local outer = out
      out = {}
      node.condition = lower_operand(statement.condition)
      node.setup = out
      out = outer
      local enclosing = loop
      loop = node
      node.body = lower_block(statement.body)
      loop = enclosing
      emit(node)
    elseif kind == "Break" then
      emit({ kind = "Break", span = statement.span })
    elseif kind == "Continue" then
      loop.continues = true
      emit({ kind = "Continue", label = loop.label, span = statement.span })
    end
  end

  lower_block = function(body)
    local outer = out
    out = {}
    for _, statement in ipairs(body) do
      lower_statement(statement)
    end
    local result = out
    out = outer
    return result
  end

  local params = {}
  for i, param in ipairs(fn.params) do
    params[i] = param.symbol
  end
  local body = lower_block(fn.body)
  return { name = fn.name, span = fn.span, params = params, locals = fn.locals, temps = temps, body = body }
end

function M.lower(program)
  local sites = {}
  local functions = {}
  for i, fn in ipairs(program.functions) do
    functions[i] = lower_function(fn, sites)
  end
  return { functions = functions, sites = sites }
end

return M
