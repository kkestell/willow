-- Checks types, definite assignment, and narrowing, annotating the tree in place.
local diag = require("compiler.diag")

local M = {}

local NUMBER = { int = "int", float = "float" }
local unary_types = {
  ["+"] = NUMBER,
  ["-"] = NUMBER,
  ["not"] = { bool = "bool" },
}

-- Result types keyed by "<left type> <right type>". Equality is handled
-- separately.
local ARITHMETIC = { ["int int"] = "int", ["float float"] = "float" }
local ORDERING = { ["int int"] = "bool", ["float float"] = "bool", ["str str"] = "bool" }
local binary_types = {
  ["+"] = { ["int int"] = "int", ["float float"] = "float", ["str str"] = "str" },
  ["-"] = ARITHMETIC,
  ["*"] = ARITHMETIC,
  ["/"] = { ["int int"] = "float", ["float float"] = "float" },
  ["//"] = ARITHMETIC,
  ["%"] = ARITHMETIC,
  ["and"] = { ["bool bool"] = "bool" },
  ["or"] = { ["bool bool"] = "bool" },
  ["<"] = ORDERING,
  ["<="] = ORDERING,
  [">"] = ORDERING,
  [">="] = ORDERING,
}

-- Built-in signatures. Each takes one argument; print, str, and len check
-- theirs separately. range is checked only as a `for` iterable.
local builtins = {
  print = { result = "None" },
  str = { result = "str" },
  int = { param = "float", result = "int" },
  float = { param = "int", result = "float" },
  len = { result = "int" },
}

local OPTIONAL = " | None"

local function optional(type)
  return type:sub(-#OPTIONAL) == OPTIONAL
end

local function base(type)
  return type:sub(1, -#OPTIONAL - 1)
end

local function assignable(target, source)
  return target == source or optional(target) and (source == "None" or source == base(target))
end

local SCALARS = { int = true, float = true, bool = true, str = true, None = true }

-- Scalars and their optionals support `==` and printing.
local function scalar(type)
  return SCALARS[optional(type) and base(type) or type] == true
end

local function list_element(type)
  return type:match("^list%[(.*)%]$")
end

local function dict_types(type)
  return type:match("^dict%[(%a+), (.*)%]$")
end

-- The index and item types for indexing `type`, or nil if it cannot be indexed.
local function index_types(type)
  local element = list_element(type)
  if element then
    return "int", element
  end
  return dict_types(type)
end

-- The type of the items `for` and `in` see: list elements, dictionary keys,
-- and the one-code-point strings of a string.
local function item_type(type)
  if type == "str" then
    return "str"
  end
  return list_element(type) or (dict_types(type))
end

-- Parameter types and result types of the string methods.
local STRING_METHODS = {
  startswith = { { "str" }, "bool" },
  endswith = { { "str" }, "bool" },
  find = { { "str" }, "int" },
  replace = { { "str", "str" }, "str" },
  strip = { {}, "str" },
  split = { { "str" }, "list[str]" },
  join = { { "list[str]" }, "str" },
}

-- Parameter types and result type of method `name` on `type`, or nil.
local function method_signature(type, name)
  if type == "str" then
    local method = STRING_METHODS[name]
    if method then
      return method[1], method[2]
    end
    return nil
  end
  local element = list_element(type)
  local key, value = dict_types(type)
  if element and name == "append" then
    return { element }, "None"
  elseif element and name == "pop" then
    return {}, element
  elseif key and name == "get" then
    return { key }, (value == "None" or optional(value)) and value or value .. OPTIONAL
  elseif key and name == "pop" then
    return { key }, value
  end
end

local function expect_type(node, expected, actual)
  if not assignable(expected, actual) then
    diag.error(node.span, "expected " .. expected .. ", received " .. actual)
  end
end

-- A flow state maps each definitely assigned symbol to its type at that point:
-- the base type where a check narrowed it, and its declared type otherwise.
-- Facts map symbols to the narrowed types a condition proves.
local NO_FACTS = {}

local function copy(map)
  local result = {}
  for key, value in pairs(map) do
    result[key] = value
  end
  return result
end

local function narrow(state, facts)
  local result = copy(state)
  for symbol, type in pairs(facts) do
    result[symbol] = type
  end
  return result
end

-- Symbols assigned in both states, narrowed where both narrow them.
local function join(a, b)
  local result = {}
  for symbol, type in pairs(a) do
    if b[symbol] then
      result[symbol] = b[symbol] == type and type or symbol.type
    end
  end
  return result
end

local function replace(state, result)
  for symbol in pairs(state) do
    state[symbol] = nil
  end
  for symbol, type in pairs(result) do
    state[symbol] = type
  end
end

-- Adds the symbol of every assignment and loop name in `body`, including
-- nested blocks.
local function assigned_symbols(body, result)
  for _, statement in ipairs(body) do
    local kind = statement.kind
    if kind == "Assign" or kind == "For" then
      result[statement.symbol] = true
    end
    if kind == "If" then
      assigned_symbols(statement.body, result)
      if statement.else_body then
        assigned_symbols(statement.else_body, result)
      end
    elseif kind == "While" or kind == "For" then
      assigned_symbols(statement.body, result)
    end
  end
  return result
end

-- Narrowing before a loop holds in it and after it only for locals the loop
-- does not assign.
local function forget_loop_narrowing(state, loop)
  for symbol in pairs(assigned_symbols({ loop }, {})) do
    if state[symbol] then
      state[symbol] = symbol.type
    end
  end
end

-- Records that `symbol` holds a value of `value_type`. A value that cannot be
-- None narrows an optional local.
local function assign(state, symbol, value_type)
  if value_type == "None" or optional(value_type) then
    state[symbol] = symbol.type
  else
    state[symbol] = value_type
  end
end

local function arguments(count)
  return count .. (count == 1 and " argument" or " arguments")
end

local function check_function(fn, records)
  -- The type of field `node.name` on a value of `object` type.
  local function field_type(node, object)
    local record = records[object]
    if not record then
      diag.error(node.span, "type " .. object .. " has no field '" .. node.name .. "'")
    end
    for _, field in ipairs(record.fields) do
      if field.name == node.name then
        return field.type.name
      end
    end
    diag.error(node.span, "record " .. object .. " has no field '" .. node.name .. "'")
  end

  local return_type = fn.return_type.name

  local check_expression

  local function check_against(node, state, expected)
    expect_type(node, expected, check_expression(node, state, expected))
  end

  -- Returns the type of `node` in `state`, then the facts that hold when it is
  -- true and when it is false. `expected`, when given, is the type a display
  -- takes.
  check_expression = function(node, state, expected)
    local kind = node.kind
    local type
    local true_facts, false_facts = NO_FACTS, NO_FACTS
    if kind == "Int" then
      type = "int"
    elseif kind == "Float" then
      type = "float"
    elseif kind == "String" then
      type = "str"
    elseif kind == "Bool" then
      type = "bool"
    elseif kind == "None" then
      type = "None"
    elseif kind == "Name" then
      type = state[node.symbol]
      if not type then
        diag.error(node.span, "variable '" .. node.name .. "' may be used before assignment")
      end
    elseif kind == "Unary" then
      local operand, operand_true, operand_false = check_expression(node.operand, state)
      type = unary_types[node.op][operand]
      if not type then
        diag.error(node.span, "operator '" .. node.op .. "' cannot be applied to " .. operand)
      end
      if node.op == "not" then
        true_facts, false_facts = operand_false, operand_true
      end
    elseif kind == "Is" then
      local operand = check_expression(node.operand, state)
      if not optional(operand) then
        diag.error(node.span, "operator '" .. node.op .. "' cannot be applied to " .. operand)
      end
      type = "bool"
      if node.operand.kind == "Name" then
        local facts = { [node.operand.symbol] = base(operand) }
        if node.op == "is" then
          false_facts = facts
        else
          true_facts = facts
        end
      end
    elseif kind == "Binary" then
      local op = node.op
      local left, left_true, left_false = check_expression(node.left, state)
      -- The right operand of `and` runs only when the left is true, and of `or`
      -- only when it is false.
      local right_state = state
      if op == "and" then
        right_state = narrow(state, left_true)
      elseif op == "or" then
        right_state = narrow(state, left_false)
      end
      local right, right_true, right_false = check_expression(node.right, right_state)
      if op == "==" or op == "!=" then
        if scalar(left) and scalar(right) and (assignable(left, right) or assignable(right, left)) then
          type = "bool"
        end
      elseif op == "in" or op == "not in" then
        local item = item_type(right)
        if item and scalar(left) and scalar(item) and (assignable(left, item) or assignable(item, left)) then
          type = "bool"
        end
      else
        type = binary_types[op][left .. " " .. right]
      end
      if not type then
        diag.error(node.span, "operator '" .. op .. "' cannot be applied to " .. left .. " and " .. right)
      end
      if op == "and" then
        true_facts = narrow(left_true, right_true)
      elseif op == "or" then
        false_facts = narrow(left_false, right_false)
      end
    elseif kind == "Call" then
      local target = node.target
      if target.kind == "Builtin" and target.name == "range" then
        diag.error(node.span, "'range' can only be used as a 'for' iterable")
      end
      local builtin = target.kind == "Builtin" and builtins[target.name]
      -- A constructor takes one argument per field.
      local params = target.kind == "Record" and target.fields or target.params
      local count = builtin and 1 or #params
      if #node.args ~= count then
        diag.error(node.span, "'" .. node.name .. "' expects " .. arguments(count) .. ", received " .. #node.args)
      end
      for i, arg in ipairs(node.args) do
        local param
        if builtin then
          param = builtin.param
        else
          param = params[i].type.name
        end
        local arg_type = check_expression(arg, state, param)
        if param then
          expect_type(arg, param, arg_type)
        end
      end
      local arg_type = builtin and node.args[1].type
      if node.name == "print" and builtin and not scalar(arg_type) then
        diag.error(node.args[1].span, "cannot print a value of type " .. arg_type)
      elseif node.name == "str" and builtin and not scalar(arg_type) then
        diag.error(node.args[1].span, "cannot convert a value of type " .. arg_type .. " to str")
      elseif node.name == "len" and builtin and arg_type ~= "str" and not index_types(arg_type) then
        diag.error(node.span, "'len' cannot be applied to " .. arg_type)
      end
      if builtin then
        type = builtin.result
      elseif target.kind == "Record" then
        type = target.name
      else
        type = target.return_type.name
      end
    elseif kind == "Field" then
      type = field_type(node, check_expression(node.object, state))
    elseif kind == "FString" then
      -- Literal text is a String part.
      for _, part in ipairs(node.parts) do
        local field = check_expression(part, state)
        if not scalar(field) then
          diag.error(part.span, "cannot format a value of type " .. field)
        end
      end
      type = "str"
    elseif kind == "Index" then
      local object = check_expression(node.object, state)
      local index, item = index_types(object)
      if not index then
        diag.error(node.span, "cannot index a value of type " .. object)
      end
      check_against(node.index, state, index)
      type = item
    elseif kind == "MethodCall" then
      local object = check_expression(node.object, state)
      local params, result = method_signature(object, node.name)
      if not params then
        diag.error(node.span, "type " .. object .. " has no method '" .. node.name .. "'")
      end
      if #node.args ~= #params then
        diag.error(node.span, "'" .. node.name .. "' expects " .. arguments(#params) .. ", received " .. #node.args)
      end
      for i, arg in ipairs(node.args) do
        check_against(arg, state, params[i])
      end
      type = result
    elseif kind == "ListDisplay" then
      local want = expected and (optional(expected) and base(expected) or expected)
      local element = want and list_element(want)
      local elements = node.elements
      local first = 1
      if not element then
        if #elements == 0 then
          diag.error(node.span, "cannot infer the element type of an empty list")
        end
        element = check_expression(elements[1], state)
        first = 2
      end
      for i = first, #elements do
        check_against(elements[i], state, element)
      end
      type = "list[" .. element .. "]"
    elseif kind == "DictDisplay" then
      local want = expected and (optional(expected) and base(expected) or expected)
      local key, value
      if want then
        key, value = dict_types(want)
      end
      local entries = node.entries
      local first = 1
      if not key then
        if #entries == 0 then
          diag.error(node.span, "cannot infer the key and value types of an empty dict")
        end
        key = check_expression(entries[1].key, state)
        if key ~= "int" and key ~= "str" then
          diag.error(entries[1].key.span, "dictionary keys must be int or str")
        end
        value = check_expression(entries[1].value, state)
        first = 2
      end
      for i = first, #entries do
        check_against(entries[i].key, state, key)
        check_against(entries[i].value, state, value)
      end
      type = "dict[" .. key .. ", " .. value .. "]"
    end
    node.type = type
    return type, true_facts, false_facts
  end

  local function check_condition(node, state)
    local type, true_facts, false_facts = check_expression(node, state)
    expect_type(node, "bool", type)
    return true_facts, false_facts
  end

  local check_block

  -- Checks one statement, updating `state`; returns true if it transfers
  -- control so that the next statement cannot run.
  local function check_statement(statement, state, in_loop)
    local kind = statement.kind
    if kind == "Assign" then
      local symbol = statement.symbol
      local expected = statement.annotation and statement.annotation.name or symbol.type
      local value_type = check_expression(statement.value, state, expected)
      if statement.annotation then
        if symbol.param then
          diag.error(statement.span, "cannot annotate parameter '" .. statement.name .. "'")
        end
        -- Statements are checked in source order, so a type means an earlier assignment.
        if symbol.type then
          diag.error(statement.span, "only the first assignment to '" .. statement.name .. "' can have an annotation")
        end
        symbol.type = statement.annotation.name
      end
      if symbol.type then
        expect_type(statement.value, symbol.type, value_type)
      else
        symbol.type = value_type
      end
      assign(state, symbol, value_type)
    elseif kind == "FieldAssign" then
      local field = field_type(statement, check_expression(statement.object, state))
      check_against(statement.value, state, field)
    elseif kind == "IndexAssign" then
      local object = check_expression(statement.object, state)
      local index, item = index_types(object)
      if not index then
        diag.error(statement.span, "cannot index a value of type " .. object)
      end
      check_against(statement.index, state, index)
      check_against(statement.value, state, item)
    elseif kind == "CallStmt" then
      check_expression(statement.call, state)
    elseif kind == "Return" then
      if statement.value then
        check_against(statement.value, state, return_type)
      else
        expect_type(statement, return_type, "None")
      end
      return true
    elseif kind == "Break" or kind == "Continue" then
      if not in_loop then
        diag.error(statement.span, "'" .. kind:lower() .. "' outside of a loop")
      end
      return true
    elseif kind == "If" then
      local true_facts, false_facts = check_condition(statement.condition, state)
      local body_state, body_transfers = check_block(statement.body, narrow(state, true_facts), in_loop)
      local else_state, else_transfers = narrow(state, false_facts), false
      if statement.else_body then
        else_state, else_transfers = check_block(statement.else_body, else_state, in_loop)
      end
      if body_transfers and else_transfers then
        return true
      elseif body_transfers then
        replace(state, else_state)
      elseif else_transfers then
        replace(state, body_state)
      else
        replace(state, join(body_state, else_state))
      end
    elseif kind == "While" then
      forget_loop_narrowing(state, statement)
      local true_facts = check_condition(statement.condition, state)
      -- The body may run zero times, so its assignments are not definite after the loop.
      check_block(statement.body, narrow(state, true_facts), true)
    elseif kind == "For" then
      -- The iterable is evaluated once, before the loop.
      local iterable = statement.iterable
      local item
      if iterable.kind == "Call" and iterable.name == "range" then
        local count = #iterable.args
        if count < 1 or count > 3 then
          diag.error(iterable.span, "'range' expects 1 to 3 arguments, received " .. count)
        end
        for _, arg in ipairs(iterable.args) do
          check_against(arg, state, "int")
        end
        item = "int"
      else
        local iterable_type = check_expression(iterable, state)
        item = item_type(iterable_type)
        if not item then
          diag.error(iterable.span, "cannot iterate over " .. iterable_type)
        end
      end
      local symbol = statement.symbol
      if symbol.type then
        expect_type(statement, symbol.type, item)
      else
        symbol.type = item
      end
      forget_loop_narrowing(state, statement)
      local body_state = copy(state)
      assign(body_state, symbol, item)
      -- As with `while`, the loop name and body assignments are not definite after the loop.
      check_block(statement.body, body_state, true)
    end
    return false
  end

  check_block = function(body, entry, in_loop)
    local state = copy(entry)
    local transfers = false
    for _, statement in ipairs(body) do
      if transfers then
        diag.error(statement.span, "unreachable statement")
      end
      transfers = check_statement(statement, state, in_loop)
    end
    return state, transfers
  end

  local state = {}
  for _, param in ipairs(fn.params) do
    param.symbol.type = param.type.name
    state[param.symbol] = param.type.name
  end
  -- Outside a loop only `return` transfers control at function level.
  local _, transfers = check_block(fn.body, state, false)
  if return_type ~= "None" and not transfers then
    diag.error(fn.span, "function '" .. fn.name .. "' must return a value on every path")
  end
end

-- Keeps diagnostics as they are and gives any other error its traceback.
local function capture(err)
  if diag.is(err) then
    return err
  end
  return debug.traceback(tostring(err), 1)
end

-- Signatures are fixed before checking, so each function's first error is
-- independent of the others; all of them are reported together.
function M.check(program)
  local records = {}
  for _, record in ipairs(program.records) do
    records[record.name] = record
  end
  local errors = {}
  for _, fn in ipairs(program.functions) do
    local ok, err = xpcall(check_function, capture, fn, records)
    if not ok then
      if not diag.is(err) then
        error(err, 0)
      end
      errors[#errors + 1] = err[1]
    end
  end
  if #errors > 0 then
    diag.raise(errors)
  end
end

return M
