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
local ORDERING = { ["int int"] = "bool", ["float float"] = "bool" }
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

-- Built-in signatures. Each takes one argument; print accepts every type.
local builtins = {
  print = { result = "None" },
  int = { param = "float", result = "int" },
  float = { param = "int", result = "float" },
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

-- Adds the symbol of every assignment in `body`, including nested blocks.
local function assigned_symbols(body, result)
  for _, statement in ipairs(body) do
    if statement.kind == "Assign" then
      result[statement.symbol] = true
    elseif statement.kind == "If" then
      assigned_symbols(statement.body, result)
      if statement.else_body then
        assigned_symbols(statement.else_body, result)
      end
    elseif statement.kind == "While" then
      assigned_symbols(statement.body, result)
    end
  end
  return result
end

local function arguments(count)
  return count .. (count == 1 and " argument" or " arguments")
end

local function check_function(fn)
  local return_type = fn.return_type.name

  -- Returns the type of `node` in `state`, then the facts that hold when it is
  -- true and when it is false.
  local function check_expression(node, state)
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
        if assignable(left, right) or assignable(right, left) then
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
      local builtin = target.kind == "Builtin" and builtins[target.name]
      local count = builtin and 1 or #target.params
      if #node.args ~= count then
        diag.error(node.span, "'" .. node.name .. "' expects " .. arguments(count) .. ", received " .. #node.args)
      end
      for i, arg in ipairs(node.args) do
        local arg_type = check_expression(arg, state)
        local param
        if builtin then
          param = builtin.param
        else
          param = target.params[i].type.name
        end
        if param then
          expect_type(arg, param, arg_type)
        end
      end
      type = builtin and builtin.result or target.return_type.name
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
      local value_type = check_expression(statement.value, state)
      local symbol = statement.symbol
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
      -- Assigning a value that cannot be None narrows an optional local.
      if value_type == "None" or optional(value_type) then
        state[symbol] = symbol.type
      else
        state[symbol] = value_type
      end
    elseif kind == "CallStmt" then
      check_expression(statement.call, state)
    elseif kind == "Return" then
      if statement.value then
        expect_type(statement.value, return_type, check_expression(statement.value, state))
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
      -- Narrowing before the loop holds in the condition, the body, and after
      -- the loop only for locals the body does not assign.
      for symbol in pairs(assigned_symbols(statement.body, {})) do
        if state[symbol] then
          state[symbol] = symbol.type
        end
      end
      local true_facts = check_condition(statement.condition, state)
      -- The body may run zero times, so its assignments are not definite after the loop.
      check_block(statement.body, narrow(state, true_facts), true)
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
  local errors = {}
  for _, fn in ipairs(program.functions) do
    local ok, err = xpcall(check_function, capture, fn)
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
