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

-- Types name records through the file-level declarations, which locals never
-- shadow.
local function check_type(type, declarations)
  for _, record in ipairs(type.records) do
    local declaration = declarations[record.name]
    if not (declaration and declaration.kind == "Record") then
      diag.error(record.span, "unknown type '" .. record.name .. "'")
    end
  end
end

local function resolve_function(fn, scope, declarations)
  local function resolve_expression(node)
    local kind = node.kind
    if kind == "Name" then
      node.symbol = scope[node.name]
      if not node.symbol then
        local declaration = declarations[node.name]
        if declaration and declaration.kind == "Record" then
          diag.error(node.span, "record '" .. node.name .. "' cannot be used as a value")
        elseif declaration or builtins[node.name] then
          diag.error(node.span, "function '" .. node.name .. "' cannot be used as a value")
        end
        diag.error(node.span, "unknown name '" .. node.name .. "'")
      end
    elseif kind == "Call" then
      if scope[node.name] then
        diag.error(node.span, "cannot call local variable '" .. node.name .. "'")
      end
      node.target = declarations[node.name] or builtins[node.name]
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
    elseif kind == "Field" then
      resolve_expression(node.object)
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
        if statement.annotation then
          check_type(statement.annotation, declarations)
        end
      elseif kind == "FieldAssign" then
        resolve_expression(statement.value)
        resolve_expression(statement.object)
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

-- Checks names that must be unique within a function's parameters or a
-- record's fields.
local function check_unique(items, what)
  local seen = {}
  for _, item in ipairs(items) do
    if seen[item.name] then
      diag.error(item.span, "duplicate " .. what .. " '" .. item.name .. "'")
    end
    seen[item.name] = true
  end
end

function M.bind(program)
  -- Functions and records share one namespace; report clashes in source order.
  local ordered = {}
  for _, fn in ipairs(program.functions) do
    ordered[#ordered + 1] = fn
  end
  for _, record in ipairs(program.records) do
    ordered[#ordered + 1] = record
  end
  table.sort(ordered, function(a, b)
    return a.span.first < b.span.first
  end)

  local declarations = {}
  for _, declaration in ipairs(ordered) do
    local name = declaration.name
    if builtins[name] then
      diag.error(declaration.span, "cannot redefine built-in function '" .. name .. "'")
    end
    if declarations[name] then
      local what = declaration.kind == "Record" and "record" or "function"
      diag.error(declaration.span, "duplicate " .. what .. " '" .. name .. "'")
    end
    declarations[name] = declaration
  end

  for _, record in ipairs(program.records) do
    check_unique(record.fields, "field")
    for _, field in ipairs(record.fields) do
      check_type(field.type, declarations)
    end
  end
  for _, fn in ipairs(program.functions) do
    check_unique(fn.params, "parameter")
    for _, param in ipairs(fn.params) do
      check_type(param.type, declarations)
    end
    check_type(fn.return_type, declarations)
  end

  local main = declarations.main
  if not (main and main.kind == "Function") then
    diag.error(program.span, "program has no main function")
  end
  if #main.params > 0 or main.return_type.name ~= "None" then
    diag.error(main.span, "main must take no parameters and return None")
  end

  for _, fn in ipairs(program.functions) do
    resolve_function(fn, collect_symbols(fn), declarations)
  end
end

return M
