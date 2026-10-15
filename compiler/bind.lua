-- Resolves names and collects function signatures, annotating the tree in place.
local diag = require("compiler.diag")

local M = {}

local builtins = {
  print = { kind = "Builtin", name = "print" },
  int = { kind = "Builtin", name = "int" },
  float = { kind = "Builtin", name = "float" },
  str = { kind = "Builtin", name = "str" },
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

local TYPE_WORDS = { int = true, float = true, bool = true, str = true, None = true, list = true, dict = true }

-- Returns declaration `name` of `module` as seen from module `from`. Names that
-- begin with `_` are private to their module.
local function lookup(from, module, name, span)
  local declaration = module.declarations[name]
  if not declaration then
    diag.error(span, "module '" .. module.name .. "' has no function or record '" .. name .. "'")
  end
  if name:sub(1, 1) == "_" and module ~= from then
    diag.error(span, "'" .. name .. "' is private to module '" .. module.name .. "'")
  end
  return declaration
end

-- Types name records through file-level declarations and imports, which
-- locals never shadow. Rewrites `type.name` to use each record's `type_name`.
local function resolve_type(type, module)
  local names = {}
  for i, ref in ipairs(type.records) do
    local declaration
    if ref.module then
      local imported = module.imported[ref.module]
      if not imported then
        diag.error(ref.span, "unknown module '" .. ref.module .. "'")
      end
      declaration = lookup(module, imported, ref.name, ref.span)
    else
      declaration = module.declarations[ref.name]
    end
    if not (declaration and declaration.kind == "Record") then
      diag.error(ref.span, "unknown type '" .. (ref.module and ref.module .. "." or "") .. ref.name .. "'")
    end
    names[i] = declaration.type_name
  end
  -- Every identifier in a type string other than a type keyword names a record,
  -- in the order of `type.records`.
  local i = 0
  type.name = (type.name:gsub("[%a_][%w_.]*", function(word)
    if not TYPE_WORDS[word] then
      i = i + 1
      return names[i]
    end
  end))
end

local function resolve_function(fn, scope, module)
  local declarations, imports = module.declarations, module.imported

  local function resolve_expression(node)
    local kind = node.kind
    if kind == "Name" then
      node.symbol = scope[node.name]
      if not node.symbol then
        local declaration = declarations[node.name]
        if imports[node.name] then
          diag.error(node.span, "module '" .. node.name .. "' cannot be used as a value")
        elseif declaration and declaration.kind == "Record" then
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
    elseif kind == "MethodCall" and node.object.kind == "Name" and not scope[node.object.name]
      and imports[node.object.name] then
      -- `module.name(...)` calls a function or constructs a record of that module.
      local imported = imports[node.object.name]
      node.kind = "Call"
      node.target = lookup(module, imported, node.name, node.span)
      node.name = node.object.name .. "." .. node.name
      node.object = nil
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
    elseif kind == "FString" then
      for _, part in ipairs(node.parts) do
        resolve_expression(part)
      end
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
          resolve_type(statement.annotation, module)
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

-- Collects one module's imports, functions, and records, which share one
-- namespace; clashes are reported in source order.
local function declare(module, modules_by_name, entry)
  local ordered = {}
  for _, import in ipairs(module.imports) do
    import.kind = "Import"
    ordered[#ordered + 1] = import
  end
  for _, fn in ipairs(module.functions) do
    ordered[#ordered + 1] = fn
  end
  for _, record in ipairs(module.records) do
    ordered[#ordered + 1] = record
  end
  table.sort(ordered, function(a, b)
    return a.span.first < b.span.first
  end)

  module.declarations, module.imported = {}, {}
  local taken = {}
  for _, declaration in ipairs(ordered) do
    local name = declaration.name
    if builtins[name] then
      diag.error(declaration.span, "cannot redefine built-in function '" .. name .. "'")
    end
    if taken[name] then
      diag.error(declaration.span, "duplicate " .. declaration.kind:lower() .. " '" .. name .. "'")
    end
    taken[name] = true
    if declaration.kind == "Import" then
      module.imported[name] = modules_by_name[name]
    else
      declaration.module = module
      module.declarations[name] = declaration
    end
    if declaration.kind == "Record" then
      declaration.type_name = module == entry and name or module.name .. "." .. name
    end
  end
end

-- Binds `modules`, the entry module first.
function M.bind(modules)
  local entry = modules[1]
  local modules_by_name = {}
  for _, module in ipairs(modules) do
    modules_by_name[module.name or ""] = module
  end
  for _, module in ipairs(modules) do
    declare(module, modules_by_name, entry)
  end

  for _, module in ipairs(modules) do
    for _, record in ipairs(module.records) do
      check_unique(record.fields, "field")
      for _, field in ipairs(record.fields) do
        resolve_type(field.type, module)
      end
    end
    for _, fn in ipairs(module.functions) do
      check_unique(fn.params, "parameter")
      for _, param in ipairs(fn.params) do
        resolve_type(param.type, module)
      end
      resolve_type(fn.return_type, module)
    end
  end

  local main = entry.declarations.main
  if not (main and main.kind == "Function") then
    diag.error(entry.span, "program has no main function")
  end
  if #main.params > 0 or main.return_type.name ~= "None" then
    diag.error(main.span, "main must take no parameters and return None")
  end

  for _, module in ipairs(modules) do
    for _, fn in ipairs(module.functions) do
      resolve_function(fn, collect_symbols(fn), module)
    end
  end
end

return M
