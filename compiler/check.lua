-- Checks types, definite assignment, and narrowing, annotating the tree in place.
local bind = require("compiler.bind")
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

-- Built-in signatures. An "any" parameter is checked separately by name. range
-- is checked only as a `for` iterable.
local builtins = {
  print = { params = { "any" }, result = "None" },
  eprint = { params = { "any" }, result = "None" },
  str = { params = { "any" }, result = "str" },
  int = { params = { "any" }, result = "int" },
  float = { params = { "any" }, result = "float" },
  len = { params = { "any" }, result = "int" },
  input = { params = {}, result = "str | None" },
  read_file = { params = { "str" }, result = "str" },
  write_file = { params = { "str", "str" }, result = "None" },
  exit = { params = { "int" }, result = "None" },
  ord = { params = { "str" }, result = "int" },
  chr = { params = { "int" }, result = "str" },
}

-- The argument types `int` and `float` convert from.
local conversions = {
  int = { float = true, str = true },
  float = { int = true, str = true },
}

local OPTIONAL = " | None"

local function optional(type)
  return type:sub(-#OPTIONAL) == OPTIONAL
end

local function base(type)
  return type:sub(1, -#OPTIONAL - 1)
end

-- The type names of every exception class, including `Exception`, set by M.check.
local exception_classes = {}

-- Exception classes are assignable to `Exception`, and optionals follow their
-- bases.
local function assignable(target, source)
  if target == source or target == "Exception" and exception_classes[source] then
    return true
  end
  return optional(target) and (source == "None" or assignable(base(target), optional(source) and base(source) or source))
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

-- Adds the symbol of every assignment, loop name, and `as` name in `body`,
-- including nested blocks.
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
    elseif kind == "Try" then
      assigned_symbols(statement.body, result)
      for _, handler in ipairs(statement.handlers) do
        if handler.symbol then
          result[handler.symbol] = true
        end
        assigned_symbols(handler.body, result)
      end
      if statement.finally_body then
        assigned_symbols(statement.finally_body, result)
      end
    end
  end
  return result
end

-- Forgets narrowing for the locals `statements` assign. Narrowing before a
-- loop holds in it and after it only for locals the loop does not assign.
local function forget_narrowing(state, statements)
  for symbol in pairs(assigned_symbols(statements, {})) do
    if state[symbol] then
      state[symbol] = symbol.type
    end
  end
end

-- Records that `symbol` holds a value of `value_type`. A value that cannot be
-- None narrows an optional local to its base.
local function assign(state, symbol, value_type)
  if value_type == "None" or optional(value_type) or not optional(symbol.type) then
    state[symbol] = symbol.type
  else
    state[symbol] = base(symbol.type)
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
  -- The number of `finally` clauses enclosing the statement being checked.
  -- `in_loop` is this count at the innermost loop, or false outside loops.
  local finally_depth = 0

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
      local count = builtin and #builtin.params or #params
      if #node.args ~= count then
        diag.error(node.span, "'" .. node.name .. "' expects " .. arguments(count) .. ", received " .. #node.args)
      end
      for i, arg in ipairs(node.args) do
        local param
        if builtin then
          param = builtin.params[i] ~= "any" and builtin.params[i] or nil
        else
          param = params[i].type.name
        end
        local arg_type = check_expression(arg, state, param)
        if param then
          expect_type(arg, param, arg_type)
        end
      end
      local arg_type = builtin and node.args[1] and node.args[1].type
      if (node.name == "print" or node.name == "eprint") and builtin and not scalar(arg_type) then
        diag.error(node.args[1].span, "cannot print a value of type " .. arg_type)
      elseif node.name == "str" and builtin and not scalar(arg_type) then
        diag.error(node.args[1].span, "cannot convert a value of type " .. arg_type .. " to str")
      elseif builtin and conversions[node.name] and arg_type and not conversions[node.name][arg_type] then
        diag.error(node.args[1].span, "cannot convert a value of type " .. arg_type .. " to " .. node.name)
      elseif node.name == "len" and builtin and arg_type ~= "str" and not index_types(arg_type) then
        diag.error(node.span, "'len' cannot be applied to " .. arg_type)
      end
      if builtin then
        type = builtin.result
      elseif target.kind == "Record" then
        type = target.type_name
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

  -- Checks a `try`, updating `state`; returns true if it transfers control.
  -- The body may stop at any statement, so clauses start from the state
  -- before the `try` without narrowing of locals the earlier parts assign.
  local function check_try(statement, state, in_loop)
    local handler_entry = copy(state)
    forget_narrowing(handler_entry, statement.body)
    local finally_entry = copy(handler_entry)
    local body_state, transfers = check_block(statement.body, state, in_loop)
    local exits = {}
    if not transfers then
      exits[1] = body_state
    end
    local named = {}
    for _, handler in ipairs(statement.handlers) do
      local class = handler.record.type_name
      if named.Exception or named[class] then
        diag.error(handler.span, "unreachable 'except' clause")
      end
      named[class] = true
      local handler_state = copy(handler_entry)
      local symbol = handler.symbol
      if symbol then
        if symbol.type then
          expect_type(handler, symbol.type, class)
        else
          symbol.type = class
        end
        assign(handler_state, symbol, class)
      end
      local exit, handler_transfers = check_block(handler.body, handler_state, in_loop)
      if not handler_transfers then
        exits[#exits + 1] = exit
      end
      transfers = transfers and handler_transfers
      forget_narrowing(finally_entry, handler.body)
      if symbol and finally_entry[symbol] then
        finally_entry[symbol] = symbol.type
      end
    end
    local result = exits[1]
    for i = 2, #exits do
      result = join(result, exits[i])
    end
    if statement.finally_body then
      finally_depth = finally_depth + 1
      local finally_state, finally_transfers = check_block(statement.finally_body, finally_entry, in_loop)
      finally_depth = finally_depth - 1
      if finally_transfers then
        return true
      end
      -- The finally clause runs after whichever part fell through.
      if result then
        local assigned = assigned_symbols(statement.finally_body, {})
        -- A local the finally clause assigns on some paths only is missing
        -- from its exit state but may no longer hold the narrowed type.
        for symbol in pairs(assigned) do
          if result[symbol] then
            result[symbol] = symbol.type
          end
        end
        for symbol, type in pairs(finally_state) do
          if assigned[symbol] or type ~= symbol.type then
            result[symbol] = type
          end
        end
      end
    end
    if transfers then
      return true
    end
    replace(state, result)
    return false
  end

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
      local call = statement.call
      check_expression(call, state)
      -- exit never returns, so it transfers control like raise.
      if call.kind == "Call" and call.target.kind == "Builtin" and call.target.name == "exit" then
        return true
      end
    elseif kind == "Return" then
      if finally_depth > 0 then
        diag.error(statement.span, "'return' cannot leave a 'finally' clause")
      end
      if statement.value then
        check_against(statement.value, state, return_type)
      else
        expect_type(statement, return_type, "None")
      end
      return true
    elseif kind == "Break" or kind == "Continue" then
      if not in_loop then
        diag.error(statement.span, "'" .. kind:lower() .. "' outside of a loop")
      elseif in_loop < finally_depth then
        diag.error(statement.span, "'" .. kind:lower() .. "' cannot leave a 'finally' clause")
      end
      return true
    elseif kind == "Raise" then
      if statement.value then
        local type = check_expression(statement.value, state)
        if not exception_classes[type] then
          diag.error(statement.value.span, "expected an exception, received " .. type)
        end
      end
      return true
    elseif kind == "Try" then
      return check_try(statement, state, in_loop)
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
      forget_narrowing(state, { statement })
      local true_facts = check_condition(statement.condition, state)
      -- The body may run zero times, so its assignments are not definite after the loop.
      check_block(statement.body, narrow(state, true_facts), finally_depth)
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
      forget_narrowing(state, { statement })
      local body_state = copy(state)
      assign(body_state, symbol, item)
      -- As with `while`, the loop name and body assignments are not definite after the loop.
      check_block(statement.body, body_state, finally_depth)
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
function M.check(modules)
  local records = {}
  for name, record in pairs(bind.exceptions) do
    records[name] = record
  end
  for _, module in ipairs(modules) do
    for _, record in ipairs(module.records) do
      records[record.type_name] = record
    end
  end
  exception_classes = {}
  for name, record in pairs(records) do
    if record.exception then
      exception_classes[name] = true
    end
  end
  local errors = {}
  for _, module in ipairs(modules) do
    for _, fn in ipairs(module.functions) do
      local ok, err = xpcall(check_function, capture, fn, records)
      if not ok then
        if not diag.is(err) then
          error(err, 0)
        end
        errors[#errors + 1] = err[1]
      end
    end
  end
  if #errors > 0 then
    diag.raise(errors)
  end
end

return M
