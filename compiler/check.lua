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

-- Result types keyed by "<left kind> <right kind>". Equality and ordering are
-- handled separately.
local ARITHMETIC = { ["int int"] = types.int, ["float float"] = types.float }
local ORDERING = { ["<"] = true, ["<="] = true, [">"] = true, [">="] = true }
local binary_types = {
  ["+"] = { ["int int"] = types.int, ["float float"] = types.float, ["str str"] = types.str, ["bytes bytes"] = types.bytes },
  ["-"] = ARITHMETIC,
  ["*"] = ARITHMETIC,
  ["/"] = { ["int int"] = types.float, ["float float"] = types.float },
  ["//"] = ARITHMETIC,
  ["%"] = ARITHMETIC,
  ["and"] = { ["bool bool"] = types.bool },
  ["or"] = { ["bool bool"] = types.bool },
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

-- The signature of method `name` on `t`, through its bound for a type
-- parameter, or nil.
local function method_of(t, name)
  return types.method(t.bound or t, name)
end

-- The iterator and item types of `t` when it satisfies `Iterable[T]`, or nil.
local function iteration(t)
  local iter = method_of(t, "iter")
  local next = iter and method_of(iter.result, "next")
  if next and types.assignable(types.protocol(stdlib.protocols.Iterable, { next.result }), t) then
    return iter.result, next.result
  end
end

-- The item type of `t` when it satisfies `Iterator[T]`, or nil.
local function advancement(t)
  local next = method_of(t, "next")
  if next and types.assignable(types.protocol(stdlib.protocols.Iterator, { next.result }), t) then
    return next.result
  end
end

-- Parameter types, result types, and parameter names of the string methods.
local STRING_METHODS = {
  startswith = { { types.str }, types.bool, { "prefix" } },
  endswith = { { types.str }, types.bool, { "suffix" } },
  find = { { types.str }, types.int, { "sub" } },
  replace = { { types.str, types.str }, types.str, { "old", "new" } },
  strip = { {}, types.str },
  split = { { types.str }, types.list(types.str), { "sep" } },
  join = { { types.list(types.str) }, types.str, { "items" } },
  encode = { {}, types.bytes },
  lower = { {}, types.str },
  upper = { {}, types.str },
  ljust = { { types.int }, types.str, { "width" } },
  rjust = { { types.int }, types.str, { "width" } },
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
      return method[1], method[2], method[3]
    end
    return nil
  end
  local element = list_element(type)
  if element and name == "append" then
    return { element }, types.None, { "v" }
  elseif element and name == "pop" then
    return {}, element
  elseif element and name == "sort" then
    return { types.bool }, types.None
  elseif type.kind == "dict" and name == "get" then
    return { type.key }, optional_of(types.expand(type.value)), { "k" }
  elseif type.kind == "dict" and name == "pop" then
    return { type.key }, types.expand(type.value), { "k" }
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

-- The member of `expected` of `kind` ("list", "dict", "tuple", or
-- "callable") that a display or built-in function value takes.
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

-- Any call may rebind a captured variable, so captured variables lose their
-- narrowing after every call.
local function forget_captured(state)
  for symbol in pairs(state) do
    if symbol.captured then
      state[symbol] = symbol.type
    end
  end
end

local function without_captured(facts)
  local result = {}
  for symbol, type in pairs(facts) do
    if not symbol.captured then
      result[symbol] = type
    end
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
    if node.kind ~= "Nonlocal" then
      result[node.symbol] = true
    end
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

-- Assigns the positions of a value of `type` to the targets of `pattern`, left
-- to right, under the rules of a plain assignment.
local function check_pattern(pattern, type, state)
  if pattern.kind == "Name" then
    local symbol = pattern.symbol
    if symbol.type then
      expect_type(pattern, symbol.type, type)
    else
      symbol.type = type
    end
    assign(state, symbol, type)
    return
  end
  if type.kind ~= "tuple" then
    diag.error(pattern.span, "cannot unpack a value of type " .. type.name)
  elseif #type.elements ~= #pattern.elements then
    diag.error(pattern.span, "cannot unpack " .. type.name .. " into " .. #pattern.elements .. " targets")
  end
  for i, element in ipairs(pattern.elements) do
    check_pattern(element, type.elements[i], state)
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

-- A copy of default `node` for one call, spanning the call, so that each call
-- checks nodes of its own.
local function copy_default(node, span)
  local copy = { kind = node.kind, value = node.value, enum = node.enum, name = node.name, span = span }
  if node.elements then
    copy.elements = {}
    for i, element in ipairs(node.elements) do
      copy.elements[i] = copy_default(element, span)
    end
  end
  return copy
end

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
    elseif params[i] and params[i].keyword_only then
      diag.error(arg.span, "'" .. name .. "' received a positional argument for keyword-only parameter '"
        .. params[i].name .. "'")
    end
    args[index] = arg
    order[i] = index
  end
  -- Defaults are trailing among positional parameters, so the last positional
  -- parameter without one ends the required ones. Missing keyword-only
  -- arguments are reported below.
  local required = 0
  for j, param in ipairs(params) do
    if not param.default and not param.keyword_only then
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
      args[j] = copy_default(default, node.span)
    end
  end
  node.args, node.order = args, order
end

-- The indexes of `node.args` after bind_args, in evaluation order: written
-- arguments, then defaults.
local function evaluation_order(node)
  local result, written = {}, {}
  for i, index in ipairs(node.order) do
    result[i], written[index] = index, true
  end
  for i in ipairs(node.args) do
    if not written[i] then
      result[#result + 1] = i
    end
  end
  return result
end

-- The substitution that call `node` of `fn`, named `name`, gives its type
-- parameters, or nil when `fn` is not generic.
local function specialize(node, name, fn)
  if not (fn.typevars and node.type_args) then
    return nil
  elseif #node.type_args ~= #fn.typevars then
    local count = #fn.typevars
    diag.error(node.span, "'" .. name .. "' expects " .. count .. (count == 1 and " type argument" or " type arguments")
      .. ", received " .. #node.type_args)
  end
  local map = {}
  for i, typevar in ipairs(fn.typevars) do
    map[typevar] = node.type_args[i]
    local unsatisfied = types.unsatisfied(typevar, node.type_args[i])
    if unsatisfied then
      diag.error(node.span, unsatisfied)
    end
  end
  return map
end

-- The protocol and argument pairs being matched by `collect`, keyed by type
-- name like `satisfies` in types.lua, so self-referential protocols terminate.
local matching = {}

-- Adds to `candidates`, lists keyed by type parameter, the types that matching
-- parameter type `param` against argument type `arg` gives those parameters.
local function collect(param, arg, candidates)
  param, arg = types.expand(param), types.expand(arg)
  if candidates[param] then
    table.insert(candidates[param], arg)
  elseif param.kind == "union" then
    -- `None` in the argument says nothing. A bare type parameter, which only
    -- appears beside `None`, takes the rest; any other member matches each of
    -- the rest's members.
    local rest = {}
    for _, m in ipairs(types.members(arg)) do
      if m ~= types.None then
        rest[#rest + 1] = m
      end
    end
    for _, p in ipairs(param.members) do
      if not candidates[p] then
        for _, m in ipairs(rest) do
          collect(p, m, candidates)
        end
      elseif #rest > 0 then
        collect(p, types.union(rest), candidates)
      end
    end
  elseif param.kind == "list" and arg.kind == "list" then
    collect(param.element, arg.element, candidates)
  elseif param.kind == "dict" and arg.kind == "dict" then
    collect(param.key, arg.key, candidates)
    collect(param.value, arg.value, candidates)
  elseif param.kind == "tuple" and arg.kind == "tuple" and #param.elements == #arg.elements then
    for i, element in ipairs(param.elements) do
      collect(element, arg.elements[i], candidates)
    end
  elseif types.generic_decl(param) and types.generic_decl(param) == types.generic_decl(arg) then
    for i, p in ipairs(param.args) do
      collect(p, arg.args[i], candidates)
    end
  elseif param.kind == "protocol" and not matching[param.name .. " <- " .. arg.name] then
    -- Another type serving a protocol matches it method by method, its
    -- parameters by name.
    local pair = param.name .. " <- " .. arg.name
    matching[pair] = true
    for _, method in ipairs(param.protocol.methods) do
      local want, have = types.method(param, method.name), types.method(arg, method.name)
      if have then
        for _, p in ipairs(want.params) do
          for _, h in ipairs(have.params) do
            if h.name == p.name then
              collect(p.type, h.type, candidates)
            end
          end
        end
        collect(want.result, have.result, candidates)
      end
    end
    matching[pair] = nil
  elseif param.kind == "callable" and (arg.kind == "callable" or arg.kind == "function") then
    local params, result = arg.params, arg.result
    if arg.kind == "function" then
      params, result = {}, arg.fn.return_type
      for i, p in ipairs(types.params(arg)) do
        params[i] = p.type
      end
    end
    for i, p in ipairs(param.params) do
      if params[i] then
        collect(p, params[i], candidates)
      end
    end
    collect(param.result, result, candidates)
  end
end

-- The candidate every other candidate in `list` is assignable to, or nil.
local function choose(list)
  for _, c in ipairs(list) do
    local all = true
    for _, other in ipairs(list) do
      all = all and types.assignable(c, other)
    end
    if all then
      return c
    end
  end
end

-- Chooses a type argument for each of `typevars` from `candidates`, records
-- them in `node.type_args`, and returns the substitution. `name` names the
-- generic in errors.
local function choose_type_args(node, name, typevars, candidates)
  local map, type_args = {}, {}
  for i, typevar in ipairs(typevars) do
    local list = candidates[typevar]
    if #list == 0 then
      diag.error(node.span, "cannot infer type parameter '" .. typevar.name .. "' of '" .. name .. "'")
    end
    map[typevar] = choose(list)
    if not map[typevar] then
      local other = list[2]
      for _, c in ipairs(list) do
        if not types.assignable(list[1], c) then
          other = c
          break
        end
      end
      diag.error(node.span, "cannot infer type parameter '" .. typevar.name .. "' of '" .. name .. "' from "
        .. list[1].name .. " and " .. other.name)
    end
    local unsatisfied = types.unsatisfied(typevar, map[typevar])
    if unsatisfied then
      diag.error(node.span, unsatisfied)
    end
    type_args[i] = map[typevar]
  end
  node.type_args = type_args
  return map
end

-- `type` with the substitution `map`, if any, applied.
local function specialized(type, map)
  return map and types.substitute(type, map) or type
end

-- Checks that a list of `type` can be sorted.
local function check_sortable(node, type)
  if not (type.kind == "list" and SORTABLE[list_element(type)]) then
    diag.error(node.span, "cannot sort a value of type " .. type.name)
  end
end

-- `entry` maps the variables `fn` captures to their types at its start.
local function check_function(fn, entry)
  -- The type of field `node.name` on a value of `object` type.
  local function field_type(node, object)
    object = object.bound or object
    if object.kind ~= "record" or object.record.native then
      diag.error(node.span, "type " .. object.name .. " has no field '" .. node.name .. "'")
    end
    for _, field in ipairs(object.record.fields) do
      if field.name == node.name then
        return types.substitute(field.type, types.record_map(object))
      end
    end
    diag.error(node.span, "class " .. object.name .. " has no field '" .. node.name .. "'")
  end

  local return_type = fn.return_type
  -- The number of `finally` clauses enclosing the statement being checked.
  -- `in_loop` is this count at the innermost loop, or false outside loops.
  local finally_depth = 0

  local check_expression, check_method
  -- The number of calls checked so far.
  local calls = 0

  local function check_against(node, state, expected)
    expect_type(node, expected, check_expression(node, state, expected))
  end

  -- Checks the arguments of call `node`, named `name`, of generic `fn` given no
  -- type arguments, and returns the substitution they and `expected`, the
  -- type the result is checked against, imply. `params` are its parameters in
  -- argument order. Each type parameter takes the one candidate that all the
  -- others are assignable to, so inference never makes up a union.
  local function infer_call(node, name, params, fn, state, expected)
    local candidates = {}
    for _, typevar in ipairs(fn.typevars) do
      candidates[typevar] = {}
    end
    -- A lambda needs its parameter types, so it waits for the other arguments.
    local lambdas = {}
    for _, i in ipairs(evaluation_order(node)) do
      local arg, param = node.args[i], params[i].type
      if arg.kind == "Lambda" and types.mentions(param, candidates) then
        lambdas[#lambdas + 1] = i
      else
        local known = not types.mentions(param, candidates) and param or nil
        collect(param, check_expression(arg, state, known), candidates)
      end
    end
    for _, i in ipairs(lambdas) do
      local chosen = {}
      for typevar, list in pairs(candidates) do
        chosen[typevar] = choose(list)
      end
      local partial = types.substitute(params[i].type, chosen)
      local target = display_member(partial, "callable")
      if not target or types.mentions(types.callable(target.params, types.None), candidates) then
        diag.error(node.args[i].span, "cannot infer the parameter types of this lambda")
      end
      -- Only a result the other arguments leave open comes from the body.
      node.args[i].infer_result = types.mentions(target.result, candidates)
      collect(params[i].type, check_expression(node.args[i], state, partial), candidates)
    end
    for _, typevar in ipairs(fn.typevars) do
      if #candidates[typevar] == 0 and expected then
        -- Only parameters the arguments leave open come from the expected result.
        collect(fn.return_type, expected, { [typevar] = candidates[typevar] })
      end
    end
    return choose_type_args(node, name, fn.typevars, candidates)
  end

  -- Checks method call `node` on an object of type `object`, whose expression
  -- is already checked, and returns the call's type.
  check_method = function(node, object, state, expected)
    if object.bound then
      -- A bounded type parameter has its bound's methods.
      object = object.bound
      node.receiver = object
    end
    local method = class_method(object, node.name)
    local params, result, names, defaults, inferred
    if object.kind == "protocol" then
      -- A protocol value exposes only its declared methods.
      local signature = types.method(object, node.name)
      if not signature then
        diag.error(node.span, "type " .. object.name .. " has no method '" .. node.name .. "'")
      end
      bind_args(node, node.name, signature.params, "parameter")
      params, result = {}, signature.result
      for i, param in ipairs(signature.params) do
        params[i] = param.type
      end
      node.protocol = object.protocol
    elseif method then
      -- A declared method binds its arguments to the parameters after `self`,
      -- with its class's type parameters replaced by the object's arguments
      -- and its own inferred.
      local class_map, rest = types.record_map(object), {}
      for i = 2, #method.params do
        local param = method.params[i]
        rest[i - 1] = {
          name = param.name, default = param.default, keyword_only = param.keyword_only,
          type = types.substitute(param.type, class_map),
        }
      end
      bind_args(node, node.name, rest, "parameter")
      result = types.substitute(method.return_type, class_map)
      inferred = method.typevars ~= nil
      if inferred then
        local map = infer_call(node, node.name, rest, { typevars = method.typevars, return_type = result }, state, expected)
        for _, param in ipairs(rest) do
          param.type = types.substitute(param.type, map)
        end
        result = types.substitute(result, map)
      end
      params = {}
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
    for _, i in ipairs(evaluation_order(node)) do
      local arg = node.args[i]
      expect_type(arg, params[i], inferred and arg.type or check_expression(arg, state, params[i]))
    end
    return result
  end

  -- Returns the type of `node` in `state`, then the facts that hold when it is
  -- true and when it is false. `expected`, when given, is the type a display
  -- or built-in function value takes.
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
      local calls_before = calls
      local right, right_true, right_false = check_expression(node.right, right_state)
      if calls ~= calls_before then
        -- A call in the right operand ends what the left proved about captured variables.
        left_true, left_false = without_captured(left_true), without_captured(left_false)
        forget_captured(state)
      end
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
      elseif ORDERING[op] then
        type = types.ordered(left, right) and types.bool or nil
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
      local generic = (target.kind == "Function" or target.kind == "Record") and target.typevars
      local map = generic and specialize(node, node.name, target)
      if builtin then
        bind_args(node, node.name, builtin_params(builtin), builtin.names and "parameter")
      else
        bind_args(node, node.name, params, target.kind == "Record" and "field" or "parameter")
      end
      local inferred = generic and not map
      if inferred then
        -- A constructor's result is its class specialized by the inferred arguments.
        local signature = target.kind == "Record" and { typevars = target.typevars, return_type = target.self_type } or target
        map = infer_call(node, node.name, params, signature, state, expected)
      end
      for _, i in ipairs(evaluation_order(node)) do
        local arg = node.args[i]
        local param
        if builtin then
          param = builtin.params[i] ~= "any" and builtin.params[i] or nil
        else
          param = specialized(params[i].type, map)
        end
        local arg_type = inferred and arg.type or check_expression(arg, state, param)
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
      elseif name == "len" and builtin and arg_type ~= types.str and arg_type ~= types.bytes and arg_type.kind ~= "tuple"
        and not index_types(arg_type) then
        diag.error(node.span, "'len' cannot be applied to " .. arg_type.name)
      end
      if builtin and (name == "iter" or name == "next") then
        -- `iter(x)` is `x.iter()` and `next(x)` is `x.next()`.
        if not (name == "iter" and iteration or advancement)(arg_type) then
          diag.error(node.span, "'" .. name .. "' cannot be applied to " .. arg_type.name)
        end
        node.kind, node.object, node.args, node.target = "MethodCall", node.args[1], {}, nil
        type = check_method(node, arg_type, state, expected)
      elseif builtin and name == "sorted" then
        check_sortable(node.args[1], arg_type)
        type = arg_type
      elseif builtin then
        type = builtin.result
      elseif target.kind == "Record" then
        type = specialized(target.self_type or target.type, map)
      else
        type = specialized(target.return_type, map)
      end
    elseif kind == "IsInstance" then
      local operand = check_expression(node.operand, state)
      local class = node.class
      for _, m in ipairs(types.members(operand)) do
        -- A class name matches its specialization in the union.
        if class.record and (m == class.record.type or m.kind == "record" and m.record == class.record)
          or not class.record and m.kind == class.name then
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
    elseif kind == "Lambda" then
      -- An expected callable gives the parameter types; the body gives the result.
      local lambda, target = node.fn, display_member(expected, "callable")
      local count = #lambda.params
      if count > 0 and not target then
        diag.error(node.span, "lambda parameters need an expected callable type")
      elseif target and #target.params ~= count then
        diag.error(node.span, "expected " .. target.name .. ", received a lambda with " .. count
          .. (count == 1 and " parameter" or " parameters"))
      end
      local entry = {}
      for _, c in ipairs(lambda.captures or {}) do
        if not state[c.symbol] then
          diag.error(c.span, "variable '" .. c.symbol.name .. "' may be used before assignment")
        end
        entry[c.symbol] = c.symbol.type
      end
      for i, param in ipairs(lambda.params) do
        param.symbol.type = target.params[i]
        entry[param.symbol] = target.params[i]
      end
      -- Creating the lambda calls nothing, so calls in its body leave captured
      -- narrowing in place.
      local body, before = lambda.body[1].value, calls
      if target and node.infer_result then
        -- A generic call infers its type arguments from the lambda's result.
        type = types.callable(target.params, check_expression(body, entry))
      elseif target then
        check_against(body, entry, target.result)
        type = target
      else
        type = types.callable({}, check_expression(body, entry))
      end
      calls = before
    elseif kind == "FunctionValue" and node.target.typevars then
      -- Explicit type arguments or an expected callable specialize a generic
      -- function, whose value takes its positional contract.
      local target, map = node.target, nil
      local callable = not node.type_args and display_member(expected, "callable")
      local positional = {}
      for _, param in ipairs(target.params) do
        if param.keyword_only and not param.default then
          diag.error(node.span, "generic function '" .. target.name .. "' has required keyword-only parameters")
        elseif not param.keyword_only and (not param.default or callable and #positional < #callable.params) then
          positional[#positional + 1] = param.type
        end
      end
      if node.type_args then
        map = specialize(node, target.name, target)
      elseif callable then
        local candidates = {}
        for _, typevar in ipairs(target.typevars) do
          candidates[typevar] = {}
        end
        collect(types.callable(positional, target.return_type), callable, candidates)
        map = choose_type_args(node, target.name, target.typevars, candidates)
      else
        diag.error(node.span, "generic function '" .. target.name .. "' needs type arguments or an expected callable type")
      end
      for i, param in ipairs(positional) do
        positional[i] = types.substitute(param, map)
      end
      type = types.callable(positional, types.substitute(target.return_type, map))
    elseif kind == "FunctionValue" then
      type = node.target.value_type
    elseif kind == "BuiltinValue" then
      -- The expected callable fixes the signature: the value is checked as a
      -- call of the built-in with arguments of the callable's parameter types.
      type = display_member(expected, "callable")
      if not type then
        diag.error(node.span, "function '" .. node.name .. "' needs an expected callable type")
      end
      local args = {}
      for i, param in ipairs(type.params) do
        args[i] = { kind = "Typed", type = param, index = i, span = node.span }
      end
      node.call = { kind = "Call", name = node.name, target = node.target, args = args, span = node.span }
      -- Taking the value calls nothing, so captured narrowing survives.
      local before = calls
      expect_type(node.call, type.result, check_expression(node.call, copy(state)))
      calls = before
    elseif kind == "Typed" then
      type = node.type
    elseif kind == "CallValue" then
      local callee = check_expression(node.callee, state)
      local name = node.callee.kind == "Name" and node.callee.name
      local params, map, inferred
      if callee.kind == "function" then
        name, params = name or callee.fn.name, types.params(callee)
        map = specialize(node, name, callee.fn)
        bind_args(node, name, params, "parameter")
        inferred = callee.fn.typevars and not map
        if inferred then
          map = infer_call(node, name, params, callee.fn, state, expected)
        end
        type = specialized(callee.fn.return_type, map)
      elseif callee.kind == "callable" then
        -- A callable takes exactly its listed positional arguments.
        params, type = {}, callee.result
        for i, param in ipairs(callee.params) do
          params[i] = { type = param }
        end
        bind_args(node, name or "callable", params)
      else
        diag.error(node.span, "cannot call a value of type " .. callee.name)
      end
      for _, i in ipairs(evaluation_order(node)) do
        local arg, param = node.args[i], specialized(params[i].type, map)
        expect_type(arg, param, inferred and arg.type or check_expression(arg, state, param))
      end
    elseif kind == "Field" then
      -- Reading a method gives it bound to the object.
      local object = check_expression(node.object, state)
      node.method = class_method(object, node.name)
      if node.method and object.args then
        diag.error(node.span, "methods of generic classes cannot be used as values")
      elseif node.method and node.method.typevars then
        diag.error(node.span, "generic method '" .. node.name .. "' cannot be used as a value")
      end
      type = node.method and node.method.value_type or field_type(node, object)
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
    elseif kind == "Index" and check_expression(node.object, state).kind == "tuple" then
      local elements, index = node.object.type.elements, node.index
      local value = index.kind == "Int" and index.value
        or index.kind == "Unary" and index.op == "-" and index.operand.kind == "Int" and -index.operand.value
      if not value then
        diag.error(index.span, "tuple index must be an integer literal")
      end
      if value < 0 then
        value = value + #elements
      end
      if value < 0 or value >= #elements then
        diag.error(index.span, "tuple index out of range")
      end
      node.position = value + 1
      type = elements[node.position]
    elseif kind == "Index" then
      local object = node.object.type
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
      type = check_method(node, check_expression(node.object, state), state, expected)
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
    elseif kind == "TupleDisplay" then
      local target = display_member(expected, "tuple")
      if target and #target.elements ~= #node.elements then
        target = nil
      end
      local elements = {}
      for i, element in ipairs(node.elements) do
        if target then
          check_against(element, state, target.elements[i])
          elements[i] = target.elements[i]
        else
          elements[i] = check_expression(element, state)
        end
      end
      type = target or types.tuple(elements)
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
    if kind == "Call" or kind == "CallValue" or kind == "MethodCall" then
      calls = calls + 1
      forget_captured(state)
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
    local before = calls
    local body_state, transfers = check_block(statement.body, state, in_loop)
    -- A clause may start after any call in the parts before it.
    if calls ~= before then
      forget_captured(handler_entry)
      forget_captured(finally_entry)
    end
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
      before = calls
      local exit, handler_transfers = check_block(handler.body, handler_state, in_loop)
      if calls ~= before then
        forget_captured(finally_entry)
      end
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
      before = calls
      local finally_state, finally_transfers = check_block(statement.finally_body, finally_entry, in_loop)
      finally_depth = finally_depth - 1
      if finally_transfers then
        return true
      end
      -- The finally clause runs after whichever part fell through.
      if result then
        if calls ~= before then
          forget_captured(result)
        end
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
    elseif kind == "Unpack" then
      check_pattern(statement.pattern, check_expression(statement.value, state), state)
    elseif kind == "Nonlocal" then
      -- Bind has already made later assignments rebind the outer variables.
    elseif kind == "FunctionDef" then
      local nested, symbol = statement.fn, statement.symbol
      -- Except for the function's own name, captures must be assigned now.
      local captures = {}
      for _, c in ipairs(nested.captures or {}) do
        if c.symbol ~= symbol and not state[c.symbol] then
          diag.error(c.span, "variable '" .. c.symbol.name .. "' may be used before assignment")
        end
        captures[#captures + 1] = c.symbol
      end
      if symbol.type then
        expect_type(statement, symbol.type, nested.value_type)
      else
        symbol.type = nested.value_type
      end
      assign(state, symbol, nested.value_type)
      -- A closure starts with the full types of what it captures.
      local entry = {}
      for _, s in ipairs(captures) do
        entry[s] = s.type
      end
      check_function(nested, entry)
    elseif kind == "FieldAssign" then
      local field = field_type(statement, check_expression(statement.object, state))
      check_against(statement.value, state, field)
    elseif kind == "IndexAssign" then
      local object = check_expression(statement.object, state)
      local index, item = index_types(object)
      if object == types.str or object == types.bytes or object.kind == "tuple" then
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
      if statement.calls then
        forget_captured(state)
      end
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
        local message
        if iterable_type.kind == "tuple" then
          item, message = types.items(iterable_type)
        else
          item = iterable_type == types.bytes and types.int or item_type(iterable_type)
        end
        local iterator = not item and not message and iteration(iterable_type)
        if iterator then
          -- The loop calls `iter` once and `next` before each step.
          local iter_call = { kind = "MethodCall", object = iterable, name = "iter", args = {}, span = iterable.span }
          iter_call.type = check_method(iter_call, iterable_type, state)
          local next_call = { kind = "MethodCall", name = "next", args = {}, span = statement.span }
          next_call.type = check_method(next_call, iterator, state)
          statement.iter_call, statement.next_call, item = iter_call, next_call, next_call.type
          calls = calls + 1
        end
        if not item then
          diag.error(iterable.span, "cannot iterate over " .. iterable_type.name .. (message and ": " .. message or ""))
        end
      end
      statement.type = item
      forget_narrowing(state, { statement })
      if statement.calls or statement.iter_call then
        forget_captured(state)
      end
      local body_state = copy(state)
      if statement.pattern then
        check_pattern(statement.pattern, item, body_state)
      else
        local symbol = statement.symbol
        if symbol.type then
          expect_type(statement, symbol.type, item)
        else
          symbol.type = item
        end
        assign(body_state, symbol, item)
      end
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

  local state = copy(entry or {})
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
