-- Checks types and definite assignment, annotating the tree in place.
local diag = require("compiler.diag")

local M = {}

local NUMBER = { int = "int", float = "float" }
local unary_types = {
  ["+"] = NUMBER,
  ["-"] = NUMBER,
  ["not"] = { bool = "bool" },
}

-- Result types keyed by "<left type> <right type>".
local ARITHMETIC = { ["int int"] = "int", ["float float"] = "float" }
local EQUALITY = {
  ["int int"] = "bool",
  ["float float"] = "bool",
  ["bool bool"] = "bool",
  ["str str"] = "bool",
  ["None None"] = "bool",
}
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
  ["=="] = EQUALITY,
  ["!="] = EQUALITY,
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

local function expect_type(node, expected, actual)
  if actual ~= expected then
    diag.error(node.span, "expected " .. expected .. ", received " .. actual)
  end
end

local function copy(set)
  local result = {}
  for key in pairs(set) do
    result[key] = true
  end
  return result
end

local function add_all(set, other)
  for key in pairs(other) do
    set[key] = true
  end
end

local function arguments(count)
  return count .. (count == 1 and " argument" or " arguments")
end

local function check_function(fn)
  local return_type = fn.return_type.name

  -- `assigned` is the set of symbols definitely assigned before `node` runs.
  local function check_expression(node, assigned)
    local kind = node.kind
    local type
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
      if not assigned[node.symbol] then
        diag.error(node.span, "variable '" .. node.name .. "' may be used before assignment")
      end
      type = node.symbol.type
    elseif kind == "Unary" then
      local operand = check_expression(node.operand, assigned)
      type = unary_types[node.op][operand]
      if not type then
        diag.error(node.span, "operator '" .. node.op .. "' cannot be applied to " .. operand)
      end
    elseif kind == "Binary" then
      local left = check_expression(node.left, assigned)
      local right = check_expression(node.right, assigned)
      type = binary_types[node.op][left .. " " .. right]
      if not type then
        diag.error(node.span, "operator '" .. node.op .. "' cannot be applied to " .. left .. " and " .. right)
      end
    elseif kind == "Call" then
      local target = node.target
      local builtin = target.kind == "Builtin" and builtins[target.name]
      local count = builtin and 1 or #target.params
      if #node.args ~= count then
        diag.error(node.span, "'" .. node.name .. "' expects " .. arguments(count) .. ", received " .. #node.args)
      end
      for i, arg in ipairs(node.args) do
        local arg_type = check_expression(arg, assigned)
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
    return type
  end

  local check_block

  -- Checks one statement, adding to `assigned`; returns true if it transfers
  -- control so that the next statement cannot run.
  local function check_statement(statement, assigned, in_loop)
    local kind = statement.kind
    if kind == "Assign" then
      local value_type = check_expression(statement.value, assigned)
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
      assigned[symbol] = true
    elseif kind == "CallStmt" then
      check_expression(statement.call, assigned)
    elseif kind == "Return" then
      if statement.value then
        expect_type(statement.value, return_type, check_expression(statement.value, assigned))
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
      expect_type(statement.condition, "bool", check_expression(statement.condition, assigned))
      local body_assigned, body_transfers = check_block(statement.body, assigned, in_loop)
      local else_assigned, else_transfers = assigned, false
      if statement.else_body then
        else_assigned, else_transfers = check_block(statement.else_body, assigned, in_loop)
      end
      -- Branch results contain the entry set, so joining only adds to it.
      if body_transfers and else_transfers then
        return true
      elseif body_transfers then
        add_all(assigned, else_assigned)
      elseif else_transfers then
        add_all(assigned, body_assigned)
      else
        for symbol in pairs(body_assigned) do
          if else_assigned[symbol] then
            assigned[symbol] = true
          end
        end
      end
    elseif kind == "While" then
      expect_type(statement.condition, "bool", check_expression(statement.condition, assigned))
      -- The body may run zero times, so its assignments are not definite after the loop.
      check_block(statement.body, assigned, true)
    end
    return false
  end

  check_block = function(body, entry, in_loop)
    local assigned = copy(entry)
    local transfers = false
    for _, statement in ipairs(body) do
      if transfers then
        diag.error(statement.span, "unreachable statement")
      end
      transfers = check_statement(statement, assigned, in_loop)
    end
    return assigned, transfers
  end

  local assigned = {}
  for _, param in ipairs(fn.params) do
    param.symbol.type = param.type.name
    assigned[param.symbol] = true
  end
  -- Outside a loop only `return` transfers control at function level.
  local _, transfers = check_block(fn.body, assigned, false)
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
