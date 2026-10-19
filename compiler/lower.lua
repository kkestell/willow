-- Lowers the checked tree into explicit evaluation order and control flow.
local bind = require("compiler.bind")
local types = require("compiler.types")

local M = {}

-- Runtime helpers for binary operations, keyed by operator and result type.
-- Other operations are plain Lua operators.
local binary_helpers = {
  ["+"] = { int = "add", bytes = "bytes_concat" },
  ["-"] = { int = "sub" },
  ["*"] = { int = "mul", float = "float_mul" },
  ["/"] = { float = "div" },
  ["//"] = { int = "int_floordiv", float = "floordiv" },
  ["%"] = { int = "int_mod", float = "mod" },
}

local function binary_helper(node)
  local helpers = binary_helpers[node.op]
  return helpers and helpers[node.type.kind]
end

-- The prefix of the runtime helpers for operations on a string, bytes, list,
-- dictionary, or native value of `type`.
local function prefix(type)
  if type.kind == "record" then
    return type.record.prefix .. "_"
  end
  return type.kind .. "_"
end

-- True when the numbers a value of `type` holds are floats.
local function is_float(type)
  return types.has(type, "float") and not types.has(type, "int")
end

-- A runtime call that cannot fail, emitted inline without a site. It takes the
-- span of its first argument, so a statement still maps to a call it wraps.
local function pure(name, args)
  return { kind = "Pure", name = name, args = args, span = args[1].span }
end

-- Converts `value` from the representation of type `from` to that of `to`,
-- boxing or unboxing floats where only one of them is boxed.
local function convert(value, from, to)
  if not to or types.boxed(to) == types.boxed(from) then
    return value
  elseif types.boxed(to) and types.has(from, "float") then
    return pure("box", { value })
  elseif types.boxed(from) and types.has(to, "float") then
    return pure("unbox", { value })
  end
  return value
end

-- The kind string __wlo_isinstance tests for `member` of a value of `type`.
local function instance_kind(member, type)
  local kind = member.kind
  if kind == "int" or kind == "float" and not types.boxed(type) then
    return "number"
  elseif kind == "float" then
    return "box"
  elseif kind == "bool" then
    return "boolean"
  elseif kind == "str" then
    return "string"
  end
  return kind
end

-- True when evaluating `node` can neither call anything nor fail, so it can be
-- evaluated wherever its value is used. Callees cannot change a caller's
-- locals, so a later call cannot change its value either. Reading a collection
-- or a field is not pure, since a later call can change the collection or
-- record.
local function is_pure(node)
  local kind = node.kind
  if kind == "Call" and node.target.kind == "Record" then
    for _, arg in ipairs(node.args) do
      if not is_pure(arg) then
        return false
      end
    end
  elseif kind == "Call" or kind == "Index" or kind == "Slice" or kind == "MethodCall" or kind == "Field" then
    return false
  elseif kind == "Unary" then
    return not (node.op == "-" and node.type == types.int) and is_pure(node.operand)
  elseif kind == "Is" or kind == "IsInstance" then
    return is_pure(node.operand)
  elseif kind == "Binary" then
    return not binary_helper(node) and node.op ~= "in" and node.op ~= "not in"
      and is_pure(node.left) and is_pure(node.right)
  elseif kind == "FString" then
    for _, part in ipairs(node.parts) do
      if not is_pure(part) then
        return false
      end
    end
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

local function lower_function(fn, sites, helpers)
  local out
  local depth, temps, labels = 0, 0, 0
  local loop
  -- The Try nodes whose protected blocks enclose the statement being lowered,
  -- and the index of each Try statement for a bare `raise`.
  local tries, try_indexes = {}, {}

  local function emit(statement)
    out[#out + 1] = statement
  end

  -- Runs `f`, returning the statements it emits and its result.
  local function capture(f)
    local outer = out
    out = {}
    local value = f()
    local body = out
    out = outer
    return body, value
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
    helpers[name] = true
    return { kind = "Helper", name = name, args = args, site = #sites, span = span }
  end

  local lower_node, lower_value, lower_operand, lower_object

  -- The text of an evaluated operand of a printable type, as print writes it.
  local function text(operand, type)
    if type == types.str then
      return operand
    end
    return { kind = "Str", value = operand, float = is_float(type) }
  end

  -- The text of f-string field `part` under format specification `spec`. A
  -- width without an alignment pads strings on the right and other values on
  -- the left; a union with a str member decides from the value it holds.
  local function formatted(part, spec)
    local operand = lower_operand(part)
    local value
    if spec and spec.type == "f" then
      value = pure("format_fixed", { operand, { kind = "Literal", value = spec.precision or 6 } })
    else
      value = text(operand, part.type)
    end
    if not (spec and spec.width) then
      return value
    end
    local align = spec.align
    if not align and part.type == types.str then
      align = "<"
    elseif not align and not types.has(part.type, "str") then
      align = ">"
    end
    local args = { value, { kind = "Literal", value = spec.width }, { kind = "Literal", value = align } }
    if not align then
      args[4] = operand
    end
    return pure("pad", args)
  end

  -- The arguments of a checked call in parameter order, evaluated in written
  -- order. The arguments left are defaults, which are literals.
  local function lower_args(node)
    local args = {}
    for _, i in ipairs(node.order) do
      args[i] = lower_operand(node.args[i])
    end
    for i, arg in ipairs(node.args) do
      args[i] = args[i] or lower_operand(arg)
    end
    return args
  end

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
    local body = capture(function()
      set(result, lower_value(node.right), node.span)
    end)
    depth = mark + 1
    local condition = node.op == "and" and result or { kind = "Not", operand = result }
    emit({ kind = "If", condition = condition, body = body, span = node.span })
    return result
  end

  -- Returns an expression of `node`'s own type whose operands contain no
  -- calls; the expression itself may be one call or helper call.
  lower_node = function(node)
    local kind = node.kind
    if kind == "Int" or kind == "Float" or kind == "String" or kind == "Bool" then
      return { kind = "Literal", value = node.value }
    elseif kind == "None" then
      return { kind = "Literal" }
    elseif kind == "Name" then
      return convert({ kind = "Local", symbol = node.symbol }, node.symbol.type, node.type)
    elseif kind == "Unary" then
      if node.op == "+" then
        return lower_value(node.operand)
      end
      local operand = lower_operand(node.operand)
      if node.op == "not" then
        return { kind = "Not", operand = operand }
      elseif node.type == types.float then
        return { kind = "Neg", operand = operand }
      end
      return helper("neg", { operand }, node.span)
    elseif kind == "Is" then
      local op = node.op == "is" and "==" or "!="
      return { kind = "Binary", op = op, left = lower_operand(node.operand), right = { kind = "Literal" } }
    elseif kind == "IsInstance" then
      local operand, declared = lower_operand(node.operand), node.member.record or node.member.enum
      if declared then
        return pure("isinstance_type", { operand, { kind = "Literal", value = declared.type_name } })
      end
      local kind_string = instance_kind(node.member, node.operand.type)
      return pure("isinstance", { operand, { kind = "Literal", value = kind_string } })
    elseif kind == "Binary" then
      if (node.op == "and" or node.op == "or") and not is_pure(node.right) then
        return lower_short_circuit(node)
      end
      local mark = depth
      local left = lower_operand(node.left)
      local right = lower_operand(node.right)
      local left_type, right_type = node.left.type, node.right.type
      if node.op == "in" or node.op == "not in" then
        local name = prefix(right_type) .. "contains"
        if right_type.kind == "list" then
          local element = types.expand(right_type.element)
          if types.boxed(left_type) and not types.boxed(element) and types.has(element, "float") then
            name = "list_contains_boxed"
          else
            left = convert(left, left_type, element)
          end
        end
        local contains = helper(name, { right, left }, node.span)
        if node.op == "in" then
          return contains
        end
        return { kind = "Not", operand = spill(contains, mark) }
      end
      if (node.op == "==" or node.op == "!=") and (types.boxed(left_type) or types.boxed(right_type)
        or types.has(left_type, "bytes") or types.has(right_type, "bytes")) then
        local wide = types.boxed(left_type) and left_type or right_type
        local equal = pure("equal", { convert(left, left_type, wide), convert(right, right_type, wide) })
        return node.op == "==" and equal or { kind = "Not", operand = equal }
      end
      local name = binary_helper(node)
      if name then
        return helper(name, { left, right }, node.span)
      end
      local op = node.type == types.str and "concat" or node.op
      return { kind = "Binary", op = op, left = left, right = right }
    elseif kind == "Call" then
      if node.name == "float" and node.args[1].type == types.int then
        -- A Willow integer is already the same Lua number as a float.
        return lower_value(node.args[1])
      end
      local args = lower_args(node)
      if node.target.kind == "Record" then
        local names = {}
        for i, field in ipairs(node.target.fields) do
          names[i] = field.name
        end
        return {
          kind = "Construct",
          names = names,
          values = args,
          class = node.target.type_name,
          exception = node.target.exception,
        }
      elseif node.target.kind == "Builtin" then
        local name = node.target.helper or node.target.name
        if name == "str" then
          return text(args[1], node.args[1].type)
        elseif (name == "print" or name == "eprint") and is_float(node.args[1].type) then
          name = name .. "_float"
        elseif (name == "int" or name == "float") and node.args[1].type == types.str then
          name = "parse_" .. name
        end
        return helper(name, args, node.span)
      end
      return {
        kind = "Call", target = node.target, args = args, span = node.span,
        qualified = node.name ~= node.target.name,
      }
    elseif kind == "EnumMember" then
      return { kind = "EnumMember", enum = node.enum, name = node.name }
    elseif kind == "Field" then
      return { kind = "Field", object = lower_object(node.object), name = node.name }
    elseif kind == "FString" then
      local parts = {}
      for i, part in ipairs(node.parts) do
        parts[i] = formatted(part, node.specs[i])
      end
      if #parts == 0 then
        return { kind = "Literal", value = "" }
      elseif #parts == 1 then
        return parts[1]
      end
      return { kind = "Concat", parts = parts }
    elseif kind == "Index" then
      local object = lower_operand(node.object)
      local index = lower_operand(node.index)
      local name = prefix(node.object.type) .. "index"
      return helper(name, { object, index }, node.span)
    elseif kind == "Slice" then
      local object = lower_operand(node.object)
      local start = node.start and lower_operand(node.start) or { kind = "Literal" }
      local stop = node.stop and lower_operand(node.stop) or { kind = "Literal" }
      return helper(prefix(node.object.type) .. "slice", { object, start, stop }, node.span)
    elseif kind == "MethodCall" then
      local object = lower_operand(node.object)
      local args = lower_args(node)
      table.insert(args, 1, object)
      if node.method then
        return { kind = "Call", target = node.method, args = args, span = node.span }
      end
      return helper(prefix(node.object.type) .. node.name, args, node.span)
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

  -- Returns an expression of the type `node` was checked against, if any.
  lower_value = function(node)
    return convert(lower_node(node), node.type, node.expected_type)
  end

  -- Returns an expression with no calls or field reads, moving a call, helper
  -- call, or field read into a temporary first.
  lower_operand = function(node)
    local mark = depth
    local value = lower_node(node)
    if value.kind == "Call" or value.kind == "Helper" or value.kind == "Field" then
      value = spill(value, mark)
    end
    return convert(value, node.type, node.expected_type)
  end

  -- Returns a local or temporary for a field's object, so a field access never
  -- begins with a parenthesized constructor, which Lua can read as a call
  -- continuing the previous statement.
  lower_object = function(node)
    local mark = depth
    local object = lower_operand(node)
    if object.kind == "Construct" then
      return spill(object, mark)
    end
    return object
  end

  local lower_block

  -- Departures from a protected block leave its closure with a code. Each
  -- crossed Try resumes the departure after its finally clause.
  local function departure(kind, value, span)
    local first = kind == "Return" and 1 or loop.tries + 1
    for i = first, #tries do
      tries[i][kind:lower() .. "s"] = true
    end
    local node = { kind = kind, value = value, exits = #tries >= first, span = span }
    if kind == "Continue" then
      loop.continues = true
      node.label = loop.label
    end
    emit(node)
  end

  -- Lowers a block that runs as a closure under `__wlo_try`, with its own
  -- temporaries.
  local function protect(body, node)
    local outer_temps = temps
    temps = 0
    tries[#tries + 1] = node
    local result = { body = lower_block(body), temps = temps }
    tries[#tries] = nil
    temps = outer_temps
    return result
  end

  local function lower_statement(statement)
    depth = 0
    local kind = statement.kind
    if kind == "Assign" then
      set({ kind = "Local", symbol = statement.symbol }, lower_value(statement.value), statement.span)
    elseif kind == "FieldAssign" then
      -- Python evaluates the value, then the object.
      local value = lower_operand(statement.value)
      local target = { kind = "Field", object = lower_object(statement.object), name = statement.name }
      set(target, value, statement.span)
    elseif kind == "IndexAssign" then
      -- Python evaluates the value, then the object, then the index.
      local value = lower_operand(statement.value)
      local object = lower_operand(statement.object)
      local index = lower_operand(statement.index)
      local name = prefix(statement.object.type) .. "set"
      local set_item = helper(name, { object, index, value }, statement.span)
      emit({ kind = "Eval", value = set_item, span = statement.span })
    elseif kind == "CallStmt" then
      -- float(x) and constructors leave nothing to evaluate as a statement once
      -- their arguments are evaluated.
      local value = lower_value(statement.call)
      if value.kind == "Call" or value.kind == "Helper" then
        emit({ kind = "Eval", value = value, span = value.span })
      end
    elseif kind == "Return" then
      -- A returned value never contains a call, so no return is a tail call.
      local value = statement.value and lower_operand(statement.value)
      departure("Return", value, statement.span)
    elseif kind == "If" then
      local condition = lower_operand(statement.condition)
      local body = lower_block(statement.body)
      local else_body = statement.else_body and lower_block(statement.else_body)
      emit({ kind = "If", condition = condition, body = body, else_body = else_body, span = statement.span })
    elseif kind == "While" then
      labels = labels + 1
      local node = { kind = "While", label = labels, tries = #tries, span = statement.span }
      node.setup, node.condition = capture(function()
        return lower_operand(statement.condition)
      end)
      local enclosing = loop
      loop = node
      node.body = lower_block(statement.body)
      loop = enclosing
      emit(node)
    elseif kind == "For" then
      labels = labels + 1
      local node = { kind = "For", label = labels, tries = #tries, span = statement.span }
      node.target = { kind = "Local", symbol = statement.symbol }
      node.value = convert({ kind = "Item" }, statement.type, statement.expected_type)
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
        local name = prefix(iterable.type) .. "items"
        node.iterator = helper(name, { lower_operand(iterable) }, statement.span)
      end
      local enclosing = loop
      loop = node
      node.body = lower_block(statement.body)
      loop = enclosing
      emit(node)
    elseif kind == "Break" or kind == "Continue" then
      departure(kind, nil, statement.span)
    elseif kind == "Assert" then
      -- The message is evaluated only when the condition is false.
      local condition = lower_operand(statement.condition)
      local body = capture(function()
        local message = statement.message and lower_operand(statement.message)
          or { kind = "Literal", value = "assertion failed" }
        emit({ kind = "Eval", value = helper("assert_fail", { message }, statement.span), span = statement.span })
      end)
      emit({ kind = "If", condition = { kind = "Not", operand = condition }, body = body, span = statement.span })
    elseif kind == "Raise" then
      local value
      if statement.value then
        value = helper("raise", { lower_operand(statement.value) }, statement.span)
      else
        value = helper("reraise", { { kind = "TryValue", index = try_indexes[statement.try] } }, statement.span)
      end
      emit({ kind = "Eval", value = value, span = statement.span })
    elseif kind == "Try" then
      labels = labels + 1
      try_indexes[statement] = labels
      local node = { kind = "Try", index = labels, span = statement.span }
      node.body = protect(statement.body, node)
      node.handlers = {}
      for i, handler in ipairs(statement.handlers) do
        local record = handler.record
        node.handlers[i] = {
          class = record.type_name ~= "Exception" and record.type_name or nil,
          target = handler.symbol and { kind = "Local", symbol = handler.symbol },
          body = protect(handler.body, node),
        }
      end
      node.finally_body = statement.finally_body and lower_block(statement.finally_body)
      -- Resume what left the protected blocks, in the try's own context.
      node.resume = capture(function()
        if node.returns then
          departure("Return", { kind = "TryValue", index = node.index })
        end
        if node.breaks then
          departure("Break")
        end
        if node.continues then
          departure("Continue")
        end
      end)
      emit(node)
    end
  end

  lower_block = function(body)
    return (capture(function()
      for _, statement in ipairs(body) do
        lower_statement(statement)
      end
    end))
  end

  local params = {}
  for i, param in ipairs(fn.params) do
    params[i] = param.symbol
  end
  local body = lower_block(fn.body)
  return {
    name = fn.name,
    module = fn.module,
    class = fn.class,
    span = fn.span,
    params = params,
    locals = fn.locals,
    temps = temps,
    body = body,
  }
end

-- Lowers every function and method of `modules`, the entry module first.
function M.lower(modules)
  local sites, helpers = {}, {}
  local functions = {}
  for _, module in ipairs(modules) do
    for _, fn in ipairs(bind.functions(module)) do
      functions[#functions + 1] = lower_function(fn, sites, helpers)
    end
  end
  return { modules = modules, functions = functions, sites = sites, helpers = helpers }
end

return M
