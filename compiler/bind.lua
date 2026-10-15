-- Resolves names and collects function signatures, annotating the tree in place.
local diag = require("compiler.diag")

local M = {}

local builtins = {
  print = { kind = "Builtin", name = "print" },
  int = { kind = "Builtin", name = "int" },
  float = { kind = "Builtin", name = "float" },
  len = { kind = "Builtin", name = "len" },
  range = { kind = "Builtin", name = "range" },
}

-- Gives the function one symbol per parameter and per assigned or loop name,
-- recording non-parameter symbols in `fn.locals` in order of first assignment.
local function collect_symbols(fn)
  local scope = {}
  for _, param in ipairs(fn.params) do
    param.symbol = { name = param.name, span = param.span, param = true }
    scope[param.name] = param.symbol
  end

  fn.locals = {}
  local function walk(body)
    for _, statement in ipairs(body) do
      local kind = statement.kind
      if (kind == "Assign" or kind == "For") and not scope[statement.name] then
        local symbol = { name = statement.name, span = statement.span }
        scope[statement.name] = symbol
        fn.locals[#fn.locals + 1] = symbol
      end
      if kind == "If" then
        walk(statement.body)
        if statement.else_body then
          walk(statement.else_body)
        end
      elseif kind == "While" or kind == "For" then
        walk(statement.body)
      end
    end
  end
  walk(fn.body)
  return scope
end

local function resolve_function(fn, scope, functions)
  local function resolve_expression(node)
    local kind = node.kind
    if kind == "Name" then
      node.symbol = scope[node.name]
      if not node.symbol then
        if functions[node.name] or builtins[node.name] then
          diag.error(node.span, "function '" .. node.name .. "' cannot be used as a value")
        end
        diag.error(node.span, "unknown name '" .. node.name .. "'")
      end
    elseif kind == "Call" then
      if scope[node.name] then
        diag.error(node.span, "cannot call local variable '" .. node.name .. "'")
      end
      node.target = functions[node.name] or builtins[node.name]
      if not node.target then
        diag.error(node.span, "unknown function '" .. node.name .. "'")
      end
      for _, arg in ipairs(node.args) do
        resolve_expression(arg)
      end
    elseif kind == "Unary" or kind == "Is" then
      resolve_expression(node.operand)
    elseif kind == "Binary" then
      resolve_expression(node.left)
      resolve_expression(node.right)
    elseif kind == "Index" then
      resolve_expression(node.object)
      resolve_expression(node.index)
    elseif kind == "MethodCall" then
      resolve_expression(node.object)
      for _, arg in ipairs(node.args) do
        resolve_expression(arg)
      end
    elseif kind == "ListDisplay" then
      for _, element in ipairs(node.elements) do
        resolve_expression(element)
      end
    elseif kind == "DictDisplay" then
      for _, entry in ipairs(node.entries) do
        resolve_expression(entry.key)
        resolve_expression(entry.value)
      end
    end
  end

  local function resolve_block(body)
    for _, statement in ipairs(body) do
      local kind = statement.kind
      if kind == "Assign" then
        resolve_expression(statement.value)
        statement.symbol = scope[statement.name]
      elseif kind == "IndexAssign" then
        resolve_expression(statement.value)
        resolve_expression(statement.object)
        resolve_expression(statement.index)
      elseif kind == "CallStmt" then
        resolve_expression(statement.call)
      elseif kind == "Return" then
        if statement.value then
          resolve_expression(statement.value)
        end
      elseif kind == "If" then
        resolve_expression(statement.condition)
        resolve_block(statement.body)
        if statement.else_body then
          resolve_block(statement.else_body)
        end
      elseif kind == "While" then
        resolve_expression(statement.condition)
        resolve_block(statement.body)
      elseif kind == "For" then
        resolve_expression(statement.iterable)
        statement.symbol = scope[statement.name]
        resolve_block(statement.body)
      end
    end
  end

  resolve_block(fn.body)
end

function M.bind(program)
  local functions = {}
  for _, fn in ipairs(program.functions) do
    if builtins[fn.name] then
      diag.error(fn.span, "cannot redefine built-in function '" .. fn.name .. "'")
    end
    if functions[fn.name] then
      diag.error(fn.span, "duplicate function '" .. fn.name .. "'")
    end
    functions[fn.name] = fn
    local params = {}
    for _, param in ipairs(fn.params) do
      if params[param.name] then
        diag.error(param.span, "duplicate parameter '" .. param.name .. "'")
      end
      params[param.name] = true
    end
  end

  local main = functions.main
  if not main then
    diag.error(program.span, "program has no main function")
  end
  if #main.params > 0 or main.return_type.name ~= "None" then
    diag.error(main.span, "main must take no parameters and return None")
  end

  for _, fn in ipairs(program.functions) do
    resolve_function(fn, collect_symbols(fn), functions)
  end
end

return M
