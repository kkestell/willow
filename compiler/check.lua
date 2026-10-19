-- Checks types, definite assignment, and narrowing, annotating the tree in place.
local ast = require("compiler.ast")
local bind = require("compiler.bind")
local diag = require("compiler.diag")
local stdlib = require("compiler.stdlib")
local types = require("compiler.types")

local M = {}

local NUMBER = { int = types.int, float = types.float }
local unary_types = {
  ["+"] = NUMBER,
  ["-"] = NUMBER,
  ["not"] = { bool = types.bool },
}

-- Result types keyed by "<left kind> <right kind>". Equality is handled
-- separately.
local ARITHMETIC = { ["int int"] = types.int, ["float float"] = types.float }
local ORDERING = { ["int int"] = types.bool, ["float float"] = types.bool, ["str str"] = types.bool }
local binary_types = {
  ["+"] = { ["int int"] = types.int, ["float float"] = types.float, ["str str"] = types.str, ["bytes bytes"] = types.bytes },
  ["-"] = ARITHMETIC,
  ["*"] = ARITHMETIC,
  ["/"] = { ["int int"] = types.float, ["float float"] = types.float },
  ["//"] = ARITHMETIC,
  ["%"] = ARITHMETIC,
  ["and"] = { ["bool bool"] = types.bool },
  ["or"] = { ["bool bool"] = types.bool },
  ["<"] = ORDERING,
  ["<="] = ORDERING,
  [">"] = ORDERING,
  [">="] = ORDERING,
}

local function optional_of(type)
  if type == types.None or types.optional(type) then
    return type
  end
  return types.union({ type, types.None })
end

-- The argument kinds `int` and `float` convert from.
local conversions = {
  int = { float = true, str = true },
  float = { int = true, str = true },
}

local function list_element(type)
  return type.kind == "list" and types.expand(type.element) or nil
end

-- The index and item types for indexing `type`, or nil if it cannot be indexed.
local function index_types(type)
  if type.kind == "list" then
    return types.int, types.expand(type.element)
  elseif type.kind == "dict" then
    return type.key, types.expand(type.value)
  end
end

-- The type of the items `for` and `in` see: list elements, dictionary keys,
-- and the one-code-point strings of a string.
local function item_type(type)
  if type == types.str then
    return types.str
  elseif type.kind == "dict" then
    return type.key
  end
  return list_element(type)
end

-- Parameter types and result types of the string methods.
local STRING_METHODS = {
  startswith = { { types.str }, types.bool },
  endswith = { { types.str }, types.bool },
  find = { { types.str }, types.int },
  replace = { { types.str, types.str }, types.str },
  strip = { {}, types.str },
  split = { { types.str }, types.list(types.str) },
  join = { { types.list(types.str) }, types.str },
  encode = { {}, types.bytes },
  lower = { {}, types.str },
  upper = { {}, types.str },
  ljust = { { types.int }, types.str },
  rjust = { { types.int }, types.str },
}

-- The element types sorted and sort accept.
local SORTABLE = { [types.int] = true, [types.float] = true, [types.str] = true }

local FORMAT_TYPES = { s = types.str, d = types.int, f = types.float }

-- Parameter types, result type, and, for methods that accept keywords, the
-- parameter names and defaults of method `name` on `type`, or nil.
local function method_signature(type, name)
  if type == types.str then
    local method = STRING_METHODS[name]
    if method then
      return method[1], method[2]
    end
    return nil
  end
  local element = list_element(type)
  if element and name == "append" then
    return { element }, types.None
  elseif element and name == "pop" then
    return {}, element
  elseif element and name == "sort" then
    return { types.bool }, types.None
  elseif type.kind == "dict" and name == "get" then
    return { type.key }, optional_of(types.expand(type.value))
  elseif type.kind == "dict" and name == "pop" then
    return { type.key }, types.expand(type.value)
  elseif type == types.bytes and name == "decode" then
    return {}, types.str
  elseif type.kind == "record" and type.record.native and type.record.native_methods[name] then
    local method = type.record.native_methods[name]
    return method.params, method.result, method.names, method.defaults
  end
end

-- The method `name` of a declared class of `type`, or nil.
local function class_method(type, name)
  if type.kind == "record" and not type.record.native then
    for _, method in ipairs(type.record.methods) do
      if method.name == name then
        return method
      end
    end
  end
end

-- Records the type `node` was checked against so lowering can convert it.
local function expect_type(node, expected, actual)
  if not types.assignable(expected, actual) then
    diag.error(node.span, "expected " .. expected.name .. ", received " .. actual.name)
  end
  node.expected_type = expected
end

-- The member of `expected` of `kind` ("list" or "dict") that a display takes.
local function display_member(expected, kind)
  for _, m in ipairs(expected and types.members(expected) or {}) do
    if m.kind == kind then
      return m
    end
  end
end

-- A flow state maps each definitely assigned symbol to its type at that point:
-- the members of its declared type a check narrowed it to, or its declared
-- type. Narrowed types are built from the declared type's member objects, so
-- membership is by identity. Facts map symbols to the narrowed types a
-- condition proves.
local NO_FACTS = {}

local function contains(type, member)
  for _, m in ipairs(types.members(type)) do
    if m == member then
      return true
    end
  end
  return false
end

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

-- Symbols assigned in both states, with the members either state allows.
local function join(a, b)
  local result = {}
  for symbol, type in pairs(a) do
    local other = b[symbol]
    if other == type then
      result[symbol] = type
    elseif other then
      result[symbol] = types.subset(symbol.type, function(m)
        return contains(type, m) or contains(other, m)
      end)
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
  ast.assignments(body, function(node)
    result[node.symbol] = true
  end)
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

-- Records that `symbol` holds a value of `value_type`. A value of one type
-- other than None narrows a union local to the member it is assignable to.
local function assign(state, symbol, value_type)
  state[symbol] = symbol.type
  if symbol.type.kind == "union" and value_type.kind ~= "union" and value_type ~= types.None then
    for _, m in ipairs(symbol.type.members) do
      if types.assignable(m, value_type) then
        state[symbol] = m
      end
    end
  end
end

local function arguments(count)
  return count .. (count == 1 and " argument" or " arguments")
end

-- Checks that `node` (a call) receives between `required` and `count`
-- arguments.
local function check_arity(node, name, required, count)
  local received = #node.args
  if received < required or received > count then
    local expected = required == count and arguments(count) or required .. " to " .. count .. " arguments"
    diag.error(node.span, "'" .. name .. "' expects " .. expected .. ", received " .. received)
  end
end

-- The parameters of `builtin` as bind_args takes them.
local function builtin_params(builtin)
  local params = {}
  for i = 1, #builtin.params do
    params[i] = { name = builtin.names and builtin.names[i], default = builtin.defaults and builtin.defaults[i] }
  end
  return params
end

local SORT_PARAMS = { { name = "reverse", default = { kind = "Bool", value = false } } }

-- Puts the arguments of call `node` in parameter order, filling omitted ones
-- with copies of their defaults, and records in `node.order` the parameter
-- index of each written argument. `params` holds `{ name, default }` entries;
-- `noun` names them in messages and is nil for a positional-only callee.
local function bind_args(node, name, params, noun)
  local args, order = {}, {}
  for i, arg in ipairs(node.args) do
    local index = i
    if arg.kind == "Keyword" then
      if not noun then
        diag.error(arg.span, "'" .. name .. "' does not accept keyword arguments")
      end
      index = nil
      for j, param in ipairs(params) do
        if param.name == arg.name then
          index = j
        end
      end
      if not index then
        diag.error(arg.span, "'" .. name .. "' has no " .. noun .. " '" .. arg.name .. "'")
      elseif args[index] then
        diag.error(arg.span, "'" .. name .. "' received more than one value for '" .. arg.name .. "'")
      end
      arg = arg.value
    end
    args[index] = arg
    order[i] = index
  end
  -- Defaults are trailing, so the last parameter without one ends the
  -- required ones.
  local required = 0
  for j, param in ipairs(params) do
    if not param.default then
      required = j
    end
  end
  check_arity(node, name, required, #params)
  for j, param in ipairs(params) do
    if not args[j] then
      local default = param.default
      if not default then
        diag.error(node.span, "'" .. name .. "' is missing argument '" .. param.name .. "'")
      end
      args[j] = { kind = default.kind, value = default.value, enum = default.enum, name = default.name, span = node.span }
    end
  end
  node.args, node.order = args, order
end

-- Checks that a list of `type` can be sorted.
local function check_sortable(node, type)
  if not (type.kind == "list" and SORTABLE[list_element(type)]) then
    diag.error(node.span, "cannot sort a value of type " .. type.name)
  end
end

local function check_function(fn)
  -- The type of field `node.name` on a value of `object` type.
  local function field_type(node, object)
    if object.kind ~= "record" or object.record.native then
      diag.error(node.span, "type " .. object.name .. " has no field '" .. node.name .. "'")
    end
    for _, field in ipairs(object.record.fields) do
      if field.name == node.name then
        return field.type
      end
    end
    diag.error(node.span, "class " .. object.name .. " has no field '" .. node.name .. "'")
  end

  local return_type = fn.return_type
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
      type = types.int
    elseif kind == "Float" then
      type = types.float
    elseif kind == "String" then
      type = types.str
    elseif kind == "Bool" then
      type = types.bool
    elseif kind == "None" then
      type = types.None
    elseif kind == "Name" then
      type = state[node.symbol]
      if not type then
        diag.error(node.span, "variable '" .. node.name .. "' may be used before assignment")
      end
    elseif kind == "Unary" then
      local operand, operand_true, operand_false = check_expression(node.operand, state)
      type = unary_types[node.op][operand.kind]
      if not type then
        diag.error(node.span, "operator '" .. node.op .. "' cannot be applied to " .. operand.name)
      end
      if node.op == "not" then
        true_facts, false_facts = operand_false, operand_true
      end
    elseif kind == "Is" then
      local operand = check_expression(node.operand, state)
      if not types.optional(operand) then
        diag.error(node.span, "operator '" .. node.op .. "' cannot be applied to " .. operand.name)
      end
      type = types.bool
      if node.operand.kind == "Name" then
        local facts = { [node.operand.symbol] = types.subset(operand, function(m)
          return m ~= types.None
        end) }
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
        if types.comparable(left) and types.comparable(right)
          and (types.assignable(left, right) or types.assignable(right, left)) then
          type = types.bool
        end
      elseif op == "in" or op == "not in" then
        -- A substring test needs a str on the left, not just a str member.
        local item = item_type(right)
        if right == types.str then
          type = left == types.str and types.bool or nil
        elseif item and types.comparable(left) and types.comparable(item)
          and (types.assignable(left, item) or types.assignable(item, left)) then
          type = types.bool
        end
      else
        type = binary_types[op][left.kind .. " " .. right.kind]
      end
      if not type then
        diag.error(node.span, "operator '" .. op .. "' cannot be applied to " .. left.name .. " and " .. right.name)
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
      local builtin = target.kind == "Builtin" and target
      if target.kind == "Record" and target.native then
        diag.error(node.span, "cannot construct native type " .. target.type_name)
      end
      -- A constructor takes one argument per field.
      local params = target.kind == "Record" and target.fields or target.params
      if builtin then
        bind_args(node, node.name, builtin_params(builtin), builtin.names and "parameter")
      else
        bind_args(node, node.name, params, target.kind == "Record" and "field" or "parameter")
      end
      for i, arg in ipairs(node.args) do
        local param
        if builtin then
          param = builtin.params[i] ~= "any" and builtin.params[i] or nil
        else
          param = params[i].type
        end
        local arg_type = check_expression(arg, state, param)
        if param then
          expect_type(arg, param, arg_type)
        end
      end
      local arg_type = builtin and node.args[1] and node.args[1].type
      local name = target.name
      if (name == "print" or name == "eprint") and builtin and not types.printable(arg_type) then
        diag.error(node.args[1].span, "cannot print a value of type " .. arg_type.name)
      elseif name == "str" and builtin and not types.printable(arg_type) then
        diag.error(node.args[1].span, "cannot convert a value of type " .. arg_type.name .. " to str")
      elseif builtin and conversions[name] and arg_type and not conversions[name][arg_type.kind] then
        diag.error(node.args[1].span, "cannot convert a value of type " .. arg_type.name .. " to " .. name)
      elseif name == "len" and builtin and arg_type ~= types.str and arg_type ~= types.bytes and not index_types(arg_type) then
        diag.error(node.span, "'len' cannot be applied to " .. arg_type.name)
      end
      if builtin and name == "sorted" then
        check_sortable(node.args[1], arg_type)
        type = arg_type
      elseif builtin then
        type = builtin.result
      elseif target.kind == "Record" then
        type = target.type
      else
        type = target.return_type
      end
    elseif kind == "IsInstance" then
      local operand = check_expression(node.operand, state)
      local class = node.class
      for _, m in ipairs(types.members(operand)) do
        if class.record and m == class.record.type or not class.record and (m.kind == class.name) then
          node.member = m
        end
      end
      if not node.member then
        local name = class.record and class.record.type_name or class.name
        diag.error(class.span, "type " .. operand.name .. " has no member " .. name)
      end
      type = types.bool
      if node.operand.kind == "Name" and operand.kind == "union" then
        local symbol = node.operand.symbol
        true_facts = { [symbol] = node.member }
        false_facts = { [symbol] = types.subset(operand, function(m)
          return m ~= node.member
        end) }
      end
    elseif kind == "EnumMember" then
      type = node.enum.type
    elseif kind == "Field" then
      type = field_type(node, check_expression(node.object, state))
    elseif kind == "FString" then
      -- Literal text is a String part.
      for i, part in ipairs(node.parts) do
        local field = check_expression(part, state)
        local spec = node.specs[i]
        local required = spec and FORMAT_TYPES[spec.type]
        if required and field ~= required then
          diag.error(part.span, "format type '" .. spec.type .. "' requires " .. required.name .. ", received " .. field.name)
        elseif not types.printable(field) then
          diag.error(part.span, "cannot format a value of type " .. field.name)
        end
      end
      type = types.str
    elseif kind == "Index" then
      local object = check_expression(node.object, state)
      local index, item = index_types(object)
      if object == types.str then
        index, item = types.int, types.str
      elseif object == types.bytes then
        index, item = types.int, types.int
      end
      if not index then
        diag.error(node.span, "cannot index a value of type " .. object.name)
      end
      check_against(node.index, state, index)
      type = item
    elseif kind == "Slice" then
      local object = check_expression(node.object, state)
      if object ~= types.str and object ~= types.bytes and object.kind ~= "list" then
        diag.error(node.span, "cannot slice a value of type " .. object.name)
      end
      if node.start then
        check_against(node.start, state, types.int)
      end
      if node.stop then
        check_against(node.stop, state, types.int)
      end
      type = object
    elseif kind == "MethodCall" then
      local object = check_expression(node.object, state)
      local method = class_method(object, node.name)
      local params, result, names, defaults
      if method then
        -- A declared method binds its arguments to the parameters after `self`.
        local rest = { unpack(method.params, 2) }
        bind_args(node, node.name, rest, "parameter")
        params, result = {}, method.return_type
        for i, param in ipairs(rest) do
          params[i] = param.type
        end
        node.method = method
      else
        params, result, names, defaults = method_signature(object, node.name)
        if not params then
          diag.error(node.span, "type " .. object.name .. " has no method '" .. node.name .. "'")
        end
        if object.kind == "list" and node.name == "sort" then
          bind_args(node, node.name, SORT_PARAMS, "parameter")
          check_sortable(node, object)
        else
          local signature = { params = params, names = names, defaults = defaults }
          bind_args(node, node.name, builtin_params(signature), names and "parameter")
        end
      end
      for i, arg in ipairs(node.args) do
        check_against(arg, state, params[i])
      end
      type = result
    elseif kind == "ListDisplay" then
      type = display_member(expected, "list")
      local element = type and list_element(type)
      local elements = node.elements
      local first = 1
      if not element then
        if #elements == 0 then
          diag.error(node.span, "cannot infer the element type of an empty list")
        end
        element = check_expression(elements[1], state)
        first = 2
        type = types.list(element)
      end
      for i = first, #elements do
        check_against(elements[i], state, element)
      end
    elseif kind == "DictDisplay" then
      type = display_member(expected, "dict")
      local key, value
      if type then
        key, value = index_types(type)
      end
      local entries = node.entries
      local first = 1
      if not key then
        if #entries == 0 then
          diag.error(node.span, "cannot infer the key and value types of an empty dict")
        end
        key = check_expression(entries[1].key, state)
        if not types.is_key(key) then
          diag.error(entries[1].key.span, "dictionary keys must be int, str, or an enum")
        end
        value = check_expression(entries[1].value, state)
        first = 2
        type = types.dict(key, value)
      end
      for i = first, #entries do
        check_against(entries[i].key, state, key)
        check_against(entries[i].value, state, value)
      end
    end
    node.type = type
    return type, true_facts, false_facts
  end

  local function check_condition(node, state)
    local type, true_facts, false_facts = check_expression(node, state)
    expect_type(node, types.bool, type)
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
      local class = handler.record.type
      if named[stdlib.exceptions.Exception] or named[handler.record] then
        diag.error(handler.span, "unreachable 'except' clause")
      end
      named[handler.record] = true
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
      local expected = statement.annotation or symbol.type
      local value_type = check_expression(statement.value, state, expected)
      if statement.annotation then
        if symbol.param then
          diag.error(statement.span, "cannot annotate parameter '" .. statement.name .. "'")
        end
        -- Statements are checked in source order, so a type means an earlier assignment.
        if symbol.type then
          diag.error(statement.span, "only the first assignment to '" .. statement.name .. "' can have an annotation")
        end
        symbol.type = statement.annotation
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
      if object == types.str or object == types.bytes then
        diag.error(statement.span, "cannot assign to an index of a value of type " .. object.name)
      elseif not index then
        diag.error(statement.span, "cannot index a value of type " .. object.name)
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
        expect_type(statement, return_type, types.None)
      end
      return true
    elseif kind == "Break" or kind == "Continue" then
      if not in_loop then
        diag.error(statement.span, "'" .. kind:lower() .. "' outside of a loop")
      elseif in_loop < finally_depth then
        diag.error(statement.span, "'" .. kind:lower() .. "' cannot leave a 'finally' clause")
      end
      return true
    elseif kind == "Assert" then
      -- The message runs only when the condition is false; later statements
      -- run only when it is true.
      local true_facts, false_facts = check_condition(statement.condition, state)
      if statement.message then
        check_against(statement.message, narrow(state, false_facts), types.str)
      end
      replace(state, narrow(state, true_facts))
    elseif kind == "Raise" then
      if statement.value then
        local type = check_expression(statement.value, state)
        if not (type.kind == "record" and type.record.exception) then
          diag.error(statement.value.span, "expected an exception, received " .. type.name)
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
        for _, arg in ipairs(iterable.args) do
          if arg.kind == "Keyword" then
            diag.error(arg.span, "'range' does not accept keyword arguments")
          end
        end
        local count = #iterable.args
        if count < 1 or count > 3 then
          diag.error(iterable.span, "'range' expects 1 to 3 arguments, received " .. count)
        end
        for _, arg in ipairs(iterable.args) do
          check_against(arg, state, types.int)
        end
        item = types.int
      else
        local iterable_type = check_expression(iterable, state)
        item = iterable_type == types.bytes and types.int or item_type(iterable_type)
        if not item then
          diag.error(iterable.span, "cannot iterate over " .. iterable_type.name)
        end
      end
      statement.type = item
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
    param.symbol.type = param.type
    state[param.symbol] = param.type
  end
  -- Outside a loop only `return` transfers control at function level.
  local _, transfers = check_block(fn.body, state, false)
  if return_type ~= types.None and not transfers then
    local name = fn.class and "method '" .. fn.class.name .. "." or "function '"
    diag.error(fn.span, name .. fn.name .. "' must return a value on every path")
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
  local errors = {}
  for _, module in ipairs(modules) do
    for _, fn in ipairs(bind.functions(module)) do
      local ok, err = xpcall(check_function, capture, fn)
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
