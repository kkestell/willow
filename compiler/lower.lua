-- Lowers the checked tree into explicit evaluation order and control flow.
local bind = require("compiler.bind")
local stdlib = require("compiler.stdlib")
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

-- The first member of `type` of `kind`, or nil.
local function member(type, kind)
  for _, m in ipairs(types.members(type)) do
    if m.kind == kind then
      return m
    end
  end
end

local convert

-- The types of the literals that library defaults, which are never checked,
-- are written as.
local literal_types = { Int = types.int, Float = types.float, String = types.str, Bool = types.bool, None = types.None }

-- A parameter's default as a lowered value of the parameter's `type`.
local function lower_default(node, type)
  local value
  if node.kind == "EnumMember" then
    value = { kind = "EnumMember", enum = node.enum, name = node.name }
  elseif node.kind == "TupleDisplay" then
    local elements = {}
    for i, element in ipairs(node.elements) do
      elements[i] = lower_default(element, element.type)
    end
    value = { kind = "Tuple", elements = elements }
  else
    value = { kind = "Literal", value = node.value }
  end
  return convert(value, node.type or literal_types[node.kind], type)
end

-- The function that lets a value of `source`, a function or callable type,
-- serve callable `target`, or nil when the value serves unchanged. It
-- converts each argument and the result and supplies omitted defaults.
local function adapter(source, target)
  local params, result, defaults = source.params, source.result, {}
  if source.kind == "function" then
    params, result = {}, source.fn.return_type
    for i, param in ipairs(types.params(source)) do
      params[i], defaults[i] = param.type, param.default
    end
  end
  local args, changed = {}, #params > #target.params
  for i, param in ipairs(target.params) do
    local placeholder = { kind = "AdapterParam", index = i }
    args[i] = convert(placeholder, param, params[i])
    changed = changed or args[i] ~= placeholder
  end
  for i = #target.params + 1, #params do
    args[i] = lower_default(defaults[i], params[i])
  end
  local call = { kind = "Call", callee = { kind = "AdapterCallee" }, args = args }
  local body = convert(call, result, target.result)
  if changed or body ~= call then
    return { kind = "Adapter", arity = #target.params, body = body }
  end
end

-- Tuple type `t` with each position of its item type, the representation its
-- iteration yields.
local function items_tuple(t)
  local items = {}
  for i = 1, #t.elements do
    items[i] = types.items(t)
  end
  return types.tuple(items)
end

-- How a value of type `from` becomes a value of type `to`, or nil when their
-- representations agree: `float` is "box" or "unbox" for a number, `[i]`
-- converts tuple position `i`, and `adapt` wraps a function.
local function conversion(from, to)
  local step = {}
  if types.boxed(to) and not types.boxed(from) and types.has(from, "float") then
    step.float = "box"
  elseif types.boxed(from) and not types.boxed(to) and types.has(to, "float") then
    step.float = "unbox"
  end
  local source, target = member(from, "tuple"), member(to, "tuple")
  if source and not target and member(to, "protocol") then
    -- A tuple serving a protocol, which iterates it, holds its items in the
    -- item type's representation.
    target = items_tuple(source)
  end
  if source and target then
    for i, element in ipairs(source.elements) do
      step[i] = conversion(element, target.elements[i])
    end
  end
  target = member(to, "callable")
  source = target and (member(from, "function") or member(from, "callable"))
  if source then
    step.adapt = adapter(source, target)
  end
  return next(step) and step or nil
end

-- Converts `value` from the representation of type `from` to that of `to`,
-- boxing or unboxing floats, including those in tuple positions, where only
-- one of them is boxed, and adapting functions to callables.
convert = function(value, from, to)
  local step = to and conversion(from, to)
  if not step then
    return value
  elseif member(from, "tuple") or step.adapt then
    return pure("convert", { value, { kind = "Literal", value = step } })
  end
  return pure(step.float, { value })
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
  elseif kind == "Call" or kind == "CallValue" or kind == "Index" or kind == "Slice" or kind == "MethodCall"
    or kind == "Field" or kind == "Await" then
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
  elseif kind == "ListDisplay" or kind == "TupleDisplay" then
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

local function lower_function(fn, sites, helpers, protocols)
  local out
  local depth, temps, labels = 0, 0, 0
  -- The `with` managers entered around the statement being lowered, and the
  -- most at once; each nesting level keeps its manager in a local of its own.
  local active, managers = 0, 0
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

  -- The converter of the type of `object`, an operand, for method `name` of
  -- `protocol`, whose table the program then gets.
  local function dispatch(protocol, object, name)
    if not protocols[protocol] then
      protocols[protocol] = true
      protocols[#protocols + 1] = protocol
    end
    return { kind = "Dispatch", protocol = protocol, object = object, name = name }
  end

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
  -- order. The arguments left are defaults: literals, enum members, or tuples of
  -- them.
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

  -- The Lua iterator over the items of `iterable`, whose checked `iter` and
  -- `next` calls `holder` keeps when it iterates through them.
  local function items_iterator(holder, iterable, span)
    if holder.iter_call then
      -- The iterator's `next` is found once and called for each step.
      local iterator = lower_operand(holder.iter_call)
      local next_call, callee = holder.next_call, nil
      if next_call.protocol then
        callee = dispatch(next_call.protocol, iterator, "next")
      elseif next_call.method then
        callee = { kind = "FunctionValue", target = next_call.method }
      else
        callee = { kind = "HelperValue", name = prefix(next_call.receiver or holder.iter_call.type) .. "next" }
        helpers[callee.name] = true
      end
      return helper("iterate", { callee, iterator }, span)
    end
    local value = lower_operand(iterable)
    if iterable.type.kind == "tuple" then
      -- Each position takes the representation of the item type.
      value = convert(value, iterable.type, items_tuple(iterable.type))
    end
    return helper(prefix(iterable.type) .. "items", { value }, span)
  end

  -- The start, stop, and step of `range` call `node`, evaluated in order.
  local function range_args(node)
    local args = {}
    for i, arg in ipairs(node.args) do
      args[i] = lower_operand(arg)
    end
    if #args == 1 then
      table.insert(args, 1, { kind = "Literal", value = 0 })
    end
    args[3] = args[3] or { kind = "Literal", value = 1 }
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
        local args = { right, left }
        if right_type.kind == "list" then
          -- A value wider than the elements compares with converted elements.
          local element = types.expand(right_type.element)
          local step = types.assignable(left_type, element) and conversion(element, left_type)
          if step then
            name = "list_contains_converted"
            args[3] = { kind = "Literal", value = step }
          else
            args[2] = convert(left, left_type, element)
          end
        end
        local contains = helper(name, args, node.span)
        if node.op == "in" then
          return contains
        end
        return { kind = "Not", operand = spill(contains, mark) }
      end
      if (node.op == "==" or node.op == "!=") and (types.boxed(left_type) or types.boxed(right_type)
        or types.has(left_type, "bytes") or types.has(right_type, "bytes")
        or types.has(left_type, "tuple") or types.has(right_type, "tuple")) then
        -- The operand of the type the other is assignable to is the wider one.
        local wide = types.assignable(left_type, right_type) and left_type or right_type
        local equal = pure("equal", { convert(left, left_type, wide), convert(right, right_type, wide) })
        return node.op == "==" and equal or { kind = "Not", operand = equal }
      end
      if left_type.kind == "tuple" then
        return pure("tuple_order", { left, right, { kind = "Literal", value = node.op } })
      end
      local name = binary_helper(node)
      if name then
        return helper(name, { left, right }, node.span)
      end
      local op = node.type == types.str and "concat" or node.op
      return { kind = "Binary", op = op, left = left, right = right }
    elseif kind == "Call" and node.target.kind == "Builtin" and node.name == "sorted"
      and node.args[1].type.kind ~= "list" then
      -- Any other iterable is collected into a new list, which is then sorted.
      local args = {}
      for _, i in ipairs(node.order) do
        args[i] = i == 1 and items_iterator(node, node.args[1], node.span) or lower_operand(node.args[i])
      end
      for i = 2, #node.args do
        args[i] = args[i] or lower_operand(node.args[i])
      end
      return helper("sort_items", args, node.span)
    elseif kind == "Call" and node.target.kind == "Builtin" and node.name == "range" then
      return helper("range_value", range_args(node), node.span)
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
        elseif name == "len" and node.args[1].type.kind == "tuple" then
          return { kind = "Literal", value = #node.args[1].type.elements }
        end
        return helper(name, args, node.span)
      end
      return {
        kind = "Call", target = node.target, args = args, span = node.span,
        qualified = node.name ~= node.target.name,
      }
    elseif kind == "EnumMember" then
      return { kind = "EnumMember", enum = node.enum, name = node.name }
    elseif kind == "Lambda" then
      -- Creating a closure has no effects, so it is set into a temporary first.
      return spill({ kind = "Closure", fn = lower_function(node.fn, sites, helpers, protocols) }, depth)
    elseif kind == "FunctionValue" then
      local value = { kind = "FunctionValue", target = node.target, qualified = node.qualified }
      -- A specialized generic function takes its callable's representation.
      return node.target.typevars and convert(value, node.target.value_type, node.type) or value
    elseif kind == "BuiltinValue" then
      return { kind = "Function", arity = #node.type.params, body = lower_value(node.call) }
    elseif kind == "Typed" then
      return { kind = "AdapterParam", index = node.index }
    elseif kind == "ManagerRef" then
      return { kind = "Manager", index = node.index }
    elseif kind == "PendingError" then
      return { kind = "PendingError", index = node.index }
    elseif kind == "Field" and node.method then
      -- The receiver is evaluated once, when the method is read.
      return pure("bind", { lower_operand(node.object), { kind = "FunctionValue", target = node.method } })
    elseif kind == "CallValue" then
      -- The callee is evaluated before the arguments.
      local callee = lower_operand(node.callee)
      return { kind = "Call", callee = callee, args = lower_args(node), span = node.span }
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
    elseif kind == "Index" and node.position then
      return { kind = "Position", object = lower_object(node.object), position = node.position }
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
    elseif kind == "MethodCall" and node.protocol then
      -- The value's own type's converter takes the receiver, the arguments in
      -- the protocol's order, with a marker for each left to a default, and
      -- the call's site.
      local object = lower_operand(node.object)
      local args = { object }
      for _, i in ipairs(node.order) do
        args[i + 1] = lower_operand(node.args[i])
      end
      for i in ipairs(node.args) do
        args[i + 1] = args[i + 1] or { kind = "Omitted" }
      end
      sites[#sites + 1] = node.span
      args[#args + 1] = { kind = "Literal", value = #sites }
      return { kind = "Call", callee = dispatch(node.protocol, object, node.name), args = args, span = node.span }
    elseif kind == "MethodCall" then
      local object = lower_operand(node.object)
      if node.name == "iter" and node.object.type.kind == "tuple" then
        object = convert(object, node.object.type, items_tuple(node.object.type))
      end
      local args = lower_args(node)
      table.insert(args, 1, object)
      if node.method then
        return { kind = "Call", target = node.method, args = args, span = node.span }
      end
      return helper(prefix(node.receiver or node.object.type) .. node.name, args, node.span)
    elseif kind == "Await" then
      local name = node.operand.type.record == stdlib.task and "aio_await_task" or "await"
      return helper(name, { lower_operand(node.operand) }, node.span)
    elseif kind == "ListDisplay" then
      local elements = {}
      for i, element in ipairs(node.elements) do
        elements[i] = lower_operand(element)
      end
      return { kind = "List", elements = elements }
    elseif kind == "TupleDisplay" then
      local elements = {}
      for i, element in ipairs(node.elements) do
        elements[i] = lower_operand(element)
      end
      return { kind = "Tuple", elements = elements }
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

  -- Returns a local or temporary for the object of a field or tuple position,
  -- so a read never begins with a parenthesized constructor, which Lua can
  -- read as a call continuing the previous statement.
  lower_object = function(node)
    local mark = depth
    local object = lower_operand(node)
    if object.kind == "Construct" or object.kind == "Tuple" then
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

  -- Lowers a block, or the statements a function emits, that runs as a closure
  -- under `__wlo_try`, with its own temporaries.
  local function protect(body, node)
    local outer_temps = temps
    temps = 0
    tries[#tries + 1] = node
    local result = { body = type(body) == "function" and (capture(body)) or lower_block(body), temps = temps }
    tries[#tries] = nil
    temps = outer_temps
    return result
  end

  -- Sets the targets of `pattern` from `value`, a temporary or the loop item
  -- holding a value of `type`.
  local function unpack_pattern(pattern, value, type)
    if pattern.kind == "Name" then
      set({ kind = "Local", symbol = pattern.symbol }, convert(value, type, pattern.expected_type), pattern.span)
    else
      for i, element in ipairs(pattern.elements) do
        unpack_pattern(element, { kind = "Position", object = value, position = i }, type.elements[i])
      end
    end
  end

  local lower_statement, lower_group

  -- Emits what leaves Try node `node`'s protected blocks, resumed in the try's
  -- own context.
  local function resume(node)
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
  end

  -- Enters item `i` of `with` statement `statement` and runs the rest under a
  -- Try whose `finally` exits it, receiving the exception leaving the body.
  local function lower_with(statement, i)
    depth = 0
    local item = statement.items[i]
    active = active + 1
    managers = math.max(managers, active)
    item.enter_call.object.index = active
    set({ kind = "Manager", index = active }, lower_value(item.manager), item.manager.span)
    local entered = lower_node(item.enter_call)
    if item.target then
      -- A tuple pattern reads the entered value once for each position.
      local value = item.target.kind == "Name" and entered or spill(entered, 0)
      unpack_pattern(item.target, value, item.enter_call.type)
    else
      emit({ kind = "Eval", value = entered, span = item.manager.span })
    end
    labels = labels + 1
    local node = { kind = "Try", index = labels, span = statement.span, handlers = {} }
    node.body = protect(function()
      if i < #statement.items then
        lower_with(statement, i + 1)
      else
        for _, inner in ipairs(statement.body) do
          lower_statement(inner)
        end
      end
    end, node)
    item.exit_call.args[1].index = node.index
    node.finally_body = capture(function()
      depth = 0
      emit({ kind = "Eval", value = lower_node(item.exit_call), span = statement.span })
    end)
    resume(node)
    emit(node)
    active = active - 1
  end

  -- Enters a task group and runs the body under a Try whose departure the
  -- group's exit joins and may replace: its failure, an outer request, or
  -- nothing once it absorbs its own stop.
  lower_group = function(statement)
    depth = 0
    active = active + 1
    managers = math.max(managers, active)
    local group = { kind = "Manager", index = active }
    set(group, lower_value(statement.manager), statement.manager.span)
    emit({ kind = "Eval", value = helper("aio_group_enter", { group }, statement.span), span = statement.span })
    if statement.target then
      set({ kind = "Local", symbol = statement.target.symbol }, group, statement.span)
    end
    labels = labels + 1
    local node = { kind = "Try", index = labels, span = statement.span, handlers = {} }
    node.body = protect(statement.body, node)
    node.exit = helper("aio_group_exit", {
      group, { kind = "TryCode", index = node.index }, { kind = "TryValue", index = node.index },
    }, statement.span)
    resume(node)
    emit(node)
    active = active - 1
  end

  lower_statement = function(statement)
    depth = 0
    local kind = statement.kind
    if kind == "FunctionDef" then
      local closure = { kind = "Closure", fn = lower_function(statement.fn, sites, helpers, protocols) }
      set({ kind = "Local", symbol = statement.symbol }, closure, statement.span)
    elseif kind == "Unpack" then
      -- A target may be the source local itself, so the source is read from a temporary.
      unpack_pattern(statement.pattern, spill(lower_value(statement.value), 0), statement.value.type)
    elseif kind == "Assign" then
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
      if not statement.pattern then
        node.target = { kind = "Local", symbol = statement.symbol }
        node.value = convert({ kind = "Item" }, statement.type, statement.expected_type)
      end
      -- The iterator is created once, after its operands are evaluated here.
      local iterable = statement.iterable
      if iterable.kind == "Call" and iterable.target.kind == "Builtin" and iterable.name == "range" then
        -- A range runs its numbers directly, so no iterator closure is made.
        -- The step is checked first, where the range is written.
        local start, stop, step = unpack(range_args(iterable))
        if step.kind ~= "Literal" or step.value == 0 then
          emit({ kind = "Eval", value = helper("range_step", { step }, iterable.span), span = iterable.span })
        end
        node.range = { start, stop, step }
      elseif iterable.type.kind == "list" then
        -- A list is read by index, which reads its length at each step, so
        -- items appended by the body are visited.
        node.list = lower_operand(iterable)
      else
        node.iterator = items_iterator(statement, iterable, statement.span)
      end
      local enclosing = loop
      loop = node
      -- The body starts by setting a pattern's targets from the item.
      local targets = statement.pattern and capture(function()
        unpack_pattern(statement.pattern, { kind = "Item" }, statement.type)
      end) or {}
      node.body = lower_block(statement.body)
      for i = #targets, 1, -1 do
        table.insert(node.body, 1, targets[i])
      end
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
    elseif kind == "Yield" then
      emit({ kind = "Eval", value = pure("yield", { lower_value(statement.value) }), span = statement.span })
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
      local node = { kind = "Try", index = labels, span = statement.span, protect = fn.async }
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
      resume(node)
      emit(node)
    elseif kind == "With" then
      lower_with(statement, 1)
    elseif kind == "AsyncWith" then
      lower_group(statement)
    end
  end

  lower_block = function(body)
    return (capture(function()
      for _, statement in ipairs(body) do
        lower_statement(statement)
      end
    end))
  end

  if fn.async then
    -- Protected blocks in async functions save and restore the task's scope.
    helpers.aio_scope, helpers.aio_set_scope = true, true
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
    managers = managers,
    body = body,
    generator = fn.generator,
    async = fn.async,
  }
end

-- The converters that let `record`, a class or native type, serve `protocol`,
-- by method name, or nil when its methods do not line up with the protocol's
-- or their concrete positions' types are not compatible.
-- They are built from the declared signatures, so one serves every
-- specialization; positions whose declared types mention a type parameter pass
-- through, as protocol compatibility requires. A converter that changes
-- nothing is the method itself.
local function converters(protocol, record, helpers)
  local methods = {}
  for _, declared in ipairs(protocol.methods) do
    local name = declared.name
    local want = types.method(protocol.self_type or protocol.type, name)
    local have = types.method(record.self_type or record.type, name)
    local indexes = have and types.match(want, have)
    if not indexes then
      return nil
    end
    local wanted = {}
    for i, j in ipairs(indexes) do
      wanted[j] = i
    end
    local args, defaults = { { kind = "AdapterParam", index = 0 } }, {}
    local changed = #have.params ~= #want.params
    for j, h in ipairs(have.params) do
      local i, value = wanted[j], nil
      if i then
        local param = want.params[i]
        local concrete = not (param.generic or h.generic)
        if concrete and not types.assignable(h.type, param.type) then
          return nil
        end
        value = { kind = "AdapterParam", index = i }
        if concrete then
          value = convert(value, param.type, h.type)
        end
        if param.default then
          -- An omitted argument takes the implementation's default, already
          -- in the implementation's representation.
          defaults[#defaults + 1] = { index = i, default = lower_default(h.default, h.type), value = value }
          value = { kind = "AdapterParam", index = i }
        end
        changed = changed or i ~= j or value.kind ~= "AdapterParam" or param.default ~= nil
      else
        value = lower_default(h.default, h.type)
      end
      args[j + 1] = value
    end
    local call, target
    if record.native then
      target = record.prefix .. "_" .. name
      helpers[target] = true
      args[#args + 1] = { kind = "AdapterSite" }
      call = { kind = "Pure", name = target, args = args }
    else
      for _, method in ipairs(record.methods) do
        if method.name == name then
          target = method
        end
      end
      call = { kind = "Call", target = target, args = args }
    end
    local body = call
    if not (want.result_generic or have.result_generic) then
      if not types.assignable(want.result, have.result) then
        return nil
      end
      body = convert(call, have.result, want.result)
    end
    if changed or body ~= call then
      methods[name] = { kind = "Converter", arity = #want.params, defaults = defaults, body = body }
    elseif record.native then
      methods[name] = { kind = "HelperValue", name = target }
    else
      methods[name] = { kind = "FunctionValue", target = target }
    end
  end
  return methods
end

-- Lowers every function and method of `modules`, the entry module first.
-- Each protocol with method calls gets converters for every class and every
-- native type of an imported library module that lines up with it.
function M.lower(modules)
  local sites, helpers, protocols = {}, {}, {}
  local functions = {}
  for _, module in ipairs(modules) do
    for _, fn in ipairs(bind.functions(module)) do
      functions[#functions + 1] = lower_function(fn, sites, helpers, protocols)
    end
  end
  local records, natives = {}, {}
  for _, module in ipairs(modules) do
    for _, record in ipairs(module.records) do
      records[#records + 1] = record
    end
    for _, imported in pairs(module.imported) do
      for _, declaration in pairs(imported.declarations) do
        if declaration.native and not natives[declaration] then
          natives[declaration] = true
          natives[#natives + 1] = declaration
        end
      end
    end
  end
  table.sort(natives, function(a, b)
    return a.type_name < b.type_name
  end)
  for _, native in ipairs(natives) do
    records[#records + 1] = native
  end
  for _, dispatched in ipairs(stdlib.dispatched) do
    records[#records + 1] = dispatched
  end
  -- Async `main` and async tests run in the event loop.
  local entry = modules[1]
  for _, fn in ipairs(entry.tests or { entry.declarations.main }) do
    if fn.async then
      helpers.aio_run = true
    end
  end
  local tables = {}
  for i, protocol in ipairs(protocols) do
    local entries = {}
    for _, record in ipairs(records) do
      local methods = converters(protocol, record, helpers)
      if methods then
        entries[#entries + 1] = { tag = record.type_name, methods = methods }
      end
    end
    tables[i] = { protocol = protocol, entries = entries }
  end
  return { modules = modules, functions = functions, sites = sites, helpers = helpers, protocols = tables }
end

return M
