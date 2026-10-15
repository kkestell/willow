-- Lowers the checked tree into explicit evaluation order and control flow.
local M = {}

-- Runtime helpers for binary operations, keyed by operator and result type.
-- Other operations are plain Lua operators.
local binary_helpers = {
  ["+"] = { int = "add" },
  ["-"] = { int = "sub" },
  ["*"] = { int = "mul", float = "float_mul" },
  ["/"] = { float = "div" },
  ["//"] = { int = "int_floordiv", float = "floordiv" },
  ["%"] = { int = "int_mod", float = "mod" },
}

local function binary_helper(node)
  local helpers = binary_helpers[node.op]
  return helpers and helpers[node.type]
end

local function is_list(type)
  return type:sub(1, 5) == "list["
end

-- True when evaluating `node` can neither call anything nor fail, so it can be
-- evaluated wherever its value is used. Callees cannot change a caller's
-- locals, so a later call cannot change its value either. Reading a collection
-- is a helper call, since a later call can change the collection.
local function is_pure(node)
  local kind = node.kind
  if kind == "Call" or kind == "Index" or kind == "MethodCall" then
    return false
  elseif kind == "Unary" then
    return not (node.op == "-" and node.type == "int") and is_pure(node.operand)
  elseif kind == "Is" then
    return is_pure(node.operand)
  elseif kind == "Binary" then
    return not binary_helper(node) and node.op ~= "in" and node.op ~= "not in"
      and is_pure(node.left) and is_pure(node.right)
  elseif kind == "ListDisplay" then
    for _, element in ipairs(node.elements) do
      if not is_pure(element) then
        return false
      end
    end
  elseif kind == "DictDisplay" then
    for _, entry in ipairs(node.entries) do
      if not (is_pure(entry.key) and is_pure(entry.value)) then
        return false
      end
    end
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

  -- Moves a call or helper call into a temporary. It consumes its operands'
  -- temporaries above `mark`, so its result reuses them.
  local function spill(value, mark)
    depth = mark
    local temp = push_temp()
    set(temp, value)
    return temp
  end

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
    if kind == "Int" or kind == "Float" or kind == "String" or kind == "Bool" then
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
      elseif node.type == "float" then
        return { kind = "Neg", operand = operand }
      end
      return helper("neg", { operand }, node.span)
    elseif kind == "Is" then
      local op = node.op == "is" and "==" or "!="
      return { kind = "Binary", op = op, left = lower_operand(node.operand), right = { kind = "Literal" } }
    elseif kind == "Binary" then
      if (node.op == "and" or node.op == "or") and not is_pure(node.right) then
        return lower_short_circuit(node)
      end
      local mark = depth
      local left = lower_operand(node.left)
      local right = lower_operand(node.right)
      if node.op == "in" or node.op == "not in" then
        local name = is_list(node.right.type) and "list_contains" or "dict_contains"
        local contains = helper(name, { right, left }, node.span)
        if node.op == "in" then
          return contains
        end
        return { kind = "Not", operand = spill(contains, mark) }
      end
      local name = binary_helper(node)
      if name then
        return helper(name, { left, right }, node.span)
      end
      local op = node.type == "str" and "concat" or node.op
      return { kind = "Binary", op = op, left = left, right = right }
    elseif kind == "Call" then
      if node.name == "float" then
        -- A Willow integer is already the same Lua number as a float.
        return lower_value(node.args[1])
      end
      local args = {}
      for i, arg in ipairs(node.args) do
        args[i] = lower_operand(arg)
      end
      if node.target.kind == "Builtin" then
        local name = node.name
        local arg_type = node.args[1].type
        if name == "print" and (arg_type == "float" or arg_type == "float | None") then
          name = "print_float"
        end
        return helper(name, args, node.span)
      end
      return { kind = "Call", target = node.target, args = args, span = node.span }
    elseif kind == "Index" then
      local object = lower_operand(node.object)
      local index = lower_operand(node.index)
      local name = is_list(node.object.type) and "list_index" or "dict_index"
      return helper(name, { object, index }, node.span)
    elseif kind == "MethodCall" then
      local args = { lower_operand(node.object) }
      for _, arg in ipairs(node.args) do
        args[#args + 1] = lower_operand(arg)
      end
      local prefix = is_list(node.object.type) and "list_" or "dict_"
      return helper(prefix .. node.name, args, node.span)
    elseif kind == "ListDisplay" then
      local elements = {}
      for i, element in ipairs(node.elements) do
        elements[i] = lower_operand(element)
      end
      return { kind = "List", elements = elements }
    elseif kind == "DictDisplay" then
      local entries = {}
      for _, entry in ipairs(node.entries) do
        entries[#entries + 1] = lower_operand(entry.key)
        entries[#entries + 1] = lower_operand(entry.value)
      end
      return { kind = "Dict", entries = entries }
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
    return spill(value, mark)
  end

  local lower_block

  local function lower_statement(statement)
    depth = 0
    local kind = statement.kind
    if kind == "Assign" then
      set({ kind = "Local", symbol = statement.symbol }, lower_value(statement.value), statement.span)
    elseif kind == "IndexAssign" then
      -- Python evaluates the value, then the object, then the index.
      local value = lower_operand(statement.value)
      local object = lower_operand(statement.object)
      local index = lower_operand(statement.index)
      local name = is_list(statement.object.type) and "list_set" or "dict_set"
      local set_item = helper(name, { object, index, value }, statement.span)
      emit({ kind = "Eval", value = set_item, span = statement.span })
    elseif kind == "CallStmt" then
      -- float(x) lowers to x, which leaves nothing to evaluate as a statement.
      local value = lower_value(statement.call)
      if value.kind == "Call" or value.kind == "Helper" then
        emit({ kind = "Eval", value = value, span = value.span })
      end
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
    elseif kind == "For" then
      labels = labels + 1
      local node = { kind = "For", label = labels, span = statement.span }
      node.target = { kind = "Local", symbol = statement.symbol }
      -- The iterator is created once, after its operands are evaluated here.
      local iterable = statement.iterable
      if iterable.kind == "Call" and iterable.name == "range" then
        local args = {}
        for i, arg in ipairs(iterable.args) do
          args[i] = lower_operand(arg)
        end
        if #args == 1 then
          table.insert(args, 1, { kind = "Literal", value = 0 })
        end
        args[3] = args[3] or { kind = "Literal", value = 1 }
        node.iterator = helper("range", args, iterable.span)
      else
        local name = is_list(iterable.type) and "list_items" or "dict_items"
        node.iterator = helper(name, { lower_operand(iterable) }, statement.span)
      end
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
