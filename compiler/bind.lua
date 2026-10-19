-- Resolves names and collects function signatures, annotating the tree in place.
local ast = require("compiler.ast")
local diag = require("compiler.diag")
local stdlib = require("compiler.stdlib")
local types = require("compiler.types")

local M = {}

local builtins, exceptions = stdlib.builtins, stdlib.exceptions

-- The functions of `module` followed by the methods of its classes.
function M.functions(module)
  local result = {}
  for _, fn in ipairs(module.functions) do
    result[#result + 1] = fn
  end
  for _, record in ipairs(module.records) do
    for _, method in ipairs(record.methods) do
      result[#result + 1] = method
    end
  end
  return result
end

-- Gives the function one symbol per parameter and per assigned or loop name,
-- recording non-parameter symbols in `fn.locals` in order of first assignment.
local function collect_symbols(fn)
  local scope = {}
  for _, param in ipairs(fn.params) do
    param.symbol = { name = param.name, span = param.span, param = true }
    scope[param.name] = param.symbol
  end

  fn.locals = {}
  ast.assignments(fn.body, function(node)
    if not scope[node.name] then
      local symbol = { name = node.name, span = node.span }
      scope[node.name] = symbol
      fn.locals[#fn.locals + 1] = symbol
    end
  end)
  return scope
end

local SCALARS = {
  int = types.int,
  float = types.float,
  bool = types.bool,
  str = types.str,
  bytes = types.bytes,
  None = types.None,
}

-- Returns declaration `name` of `module` as seen from module `from`. Names that
-- begin with `_` are private to their module.
local function lookup(from, module, name, span)
  local declaration = module.declarations[name]
  if not declaration then
    diag.error(span, "module '" .. module.name .. "' has no function, class, enum, or alias '" .. name .. "'")
  end
  if name:sub(1, 1) == "_" and module ~= from then
    diag.error(span, "'" .. name .. "' is private to module '" .. module.name .. "'")
  end
  return declaration
end

-- Returns the record, enum, or alias that `ref`, a `{ name, module, span }` in a type,
-- an `except` clause, or `isinstance`, names. These are found through
-- file-level declarations, imports, and built-in exception classes, which
-- locals never shadow.
local function resolve_named(ref, module)
  local declaration
  if ref.module then
    local imported = module.imported[ref.module]
    if not imported then
      diag.error(ref.span, "unknown module '" .. ref.module .. "'")
    end
    declaration = lookup(module, imported, ref.name, ref.span)
  else
    declaration = module.declarations[ref.name] or exceptions[ref.name]
  end
  local kind = declaration and declaration.kind
  if not (kind == "Record" or kind == "Enum" or kind == "Alias") then
    diag.error(ref.span, "unknown type '" .. (ref.module and ref.module .. "." or "") .. ref.name .. "'")
  end
  return declaration
end

-- Lazy list elements and dict values waiting to be resolved.
local pending = {}

-- The source text of type `node`, with declarations named by their type_name.
local function type_text(node, module)
  if node.kind == "UnionType" then
    local names = {}
    for i, member in ipairs(node.members) do
      names[i] = type_text(member, module)
    end
    return table.concat(names, " | ")
  elseif node.name == "list" then
    return "list[" .. type_text(node.args[1], module) .. "]"
  elseif node.name == "dict" then
    return "dict[" .. type_text(node.args[1], module) .. ", " .. type_text(node.args[2], module) .. "]"
  elseif SCALARS[node.name] then
    return node.name
  end
  return resolve_named(node, module).type_name
end

local resolve_type

local function lazy(node, module)
  local t = { kind = "lazy", name = type_text(node, module), node = node, module = module }
  pending[#pending + 1] = t
  return t
end

-- Resolves every lazy type; resolving one may queue more.
local function force_pending()
  while #pending > 0 do
    local t = table.remove(pending)
    t.type = resolve_type(t.node, t.module)
  end
end

-- Sets `decl.type` to the type alias `decl` names. Its list elements and dict
-- values are lazy, so only other positions can reach an alias being resolved.
local function resolve_alias(decl)
  if not decl.type then
    decl.resolving = true
    local name = decl.value.kind == "UnionType" and decl.type_name or nil
    decl.type = resolve_type(decl.value, decl.module, name)
    decl.resolving = nil
  end
  return decl.type
end

-- Returns the type object for type node `node`. `name` names a union.
resolve_type = function(node, module, name)
  if node.kind == "UnionType" then
    local members = {}
    for _, member in ipairs(node.members) do
      for _, m in ipairs(types.members(resolve_type(member, module))) do
        local message = types.conflict(members, m)
        if message then
          diag.error(member.span, message)
        end
        members[#members + 1] = m
      end
    end
    return types.union(members, name)
  elseif node.name == "list" then
    return types.list(lazy(node.args[1], module))
  elseif node.name == "dict" then
    local key = resolve_type(node.args[1], module)
    if key ~= types.int and key ~= types.str then
      diag.error(node.args[1].span, "dictionary keys must be int or str")
    end
    return types.dict(key, lazy(node.args[2], module))
  elseif SCALARS[node.name] then
    return SCALARS[node.name]
  end
  local declaration = resolve_named(node, module)
  if declaration.kind == "Alias" then
    if declaration.resolving then
      diag.error(node.span, "alias '" .. declaration.name .. "' expands to itself")
    end
    return resolve_alias(declaration)
  end
  return declaration.type
end

-- The dotted module name `node` spells, a `Name` or `Field`s on one, or nil.
local function qualified_name(node)
  if node.kind == "Name" then
    return node.name, node.name
  elseif node.kind == "Field" then
    local path, root = qualified_name(node.object)
    return path and path .. "." .. node.name, root
  end
end

local function resolve_function(fn, scope, module)
  local declarations, imports, roots = module.declarations, module.imported, module.roots

  -- The module name a method call's object spells when it starts with an
  -- import's root that no local shadows, or nil.
  local function module_path(object)
    local path, root = qualified_name(object)
    if path and not scope[root] and roots[root] then
      return path
    end
  end

  -- The enum that `node` names as `E` or `module.E` when no local shadows it,
  -- or nil.
  local function enum_named(node)
    local path, root = qualified_name(node)
    if not path or scope[root] then
      return nil
    end
    local declaration
    if path == root then
      declaration = declarations[path]
    elseif roots[root] then
      local prefix, name = path:match("^(.*)%.([^.]*)$")
      declaration = imports[prefix] and lookup(module, imports[prefix], name, node.span)
    end
    if declaration and declaration.kind == "Enum" then
      return declaration
    end
  end

  local function resolve_expression(node)
    local kind = node.kind
    if kind == "Name" then
      node.symbol = scope[node.name]
      if not node.symbol then
        local declaration = declarations[node.name]
        if roots[node.name] then
          diag.error(node.span, "module '" .. node.name .. "' cannot be used as a value")
        elseif declaration and declaration.kind == "Record" or exceptions[node.name] then
          diag.error(node.span, "class '" .. node.name .. "' cannot be used as a value")
        elseif declaration and (declaration.kind == "Alias" or declaration.kind == "Enum") then
          diag.error(node.span, declaration.kind:lower() .. " '" .. node.name .. "' cannot be used as a value")
        elseif declaration or builtins[node.name] then
          diag.error(node.span, "function '" .. node.name .. "' cannot be used as a value")
        end
        diag.error(node.span, "unknown name '" .. node.name .. "'")
      end
    elseif kind == "Call" then
      if scope[node.name] then
        diag.error(node.span, "cannot call local variable '" .. node.name .. "'")
      end
      node.target = declarations[node.name] or builtins[node.name] or exceptions[node.name]
      if not node.target then
        diag.error(node.span, "unknown function '" .. node.name .. "'")
      elseif node.target.kind == "Alias" or node.target.kind == "Enum" then
        diag.error(node.span, node.target.kind:lower() .. " '" .. node.name .. "' cannot be called")
      end
      for _, arg in ipairs(node.args) do
        resolve_expression(arg)
      end
    elseif kind == "MethodCall" and enum_named(node.object) then
      diag.error(node.span, "enum '" .. enum_named(node.object).type_name .. "' has no method '" .. node.name .. "'")
    elseif kind == "MethodCall" and module_path(node.object) then
      -- `module.name(...)` calls a function or constructs a record of that module.
      local path = module_path(node.object)
      local imported = imports[path]
      if not imported then
        diag.error(node.object.span, "unknown module '" .. path .. "'")
      end
      node.kind = "Call"
      node.target = lookup(module, imported, node.name, node.span)
      node.name = path .. "." .. node.name
      if node.target.kind == "Alias" or node.target.kind == "Enum" then
        diag.error(node.span, node.target.kind:lower() .. " '" .. node.name .. "' cannot be called")
      end
      node.object = nil
      for _, arg in ipairs(node.args) do
        resolve_expression(arg)
      end
    elseif kind == "Unary" or kind == "Is" then
      resolve_expression(node.operand)
    elseif kind == "IsInstance" then
      if scope.isinstance then
        diag.error(node.span, "cannot call local variable 'isinstance'")
      end
      resolve_expression(node.operand)
      local class = node.class
      if class.module or not SCALARS[class.name] and class.name ~= "list" and class.name ~= "dict" then
        local declaration = resolve_named(class, module)
        if declaration.kind == "Alias" then
          diag.error(class.span, "alias '" .. class.name .. "' cannot be used in isinstance")
        end
        class.record = declaration
      end
    elseif kind == "Binary" then
      resolve_expression(node.left)
      resolve_expression(node.right)
    elseif kind == "Index" then
      resolve_expression(node.object)
      resolve_expression(node.index)
    elseif kind == "Slice" then
      resolve_expression(node.object)
      if node.start then
        resolve_expression(node.start)
      end
      if node.stop then
        resolve_expression(node.stop)
      end
    elseif kind == "Keyword" then
      resolve_expression(node.value)
    elseif kind == "Field" and enum_named(node.object) then
      local enum = enum_named(node.object)
      local found = false
      for _, member in ipairs(enum.members) do
        found = found or member.name == node.name
      end
      if not found then
        diag.error(node.span, "enum '" .. enum.type_name .. "' has no member '" .. node.name .. "'")
      end
      node.kind, node.enum, node.object = "EnumMember", enum, nil
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

  -- `handling` is the innermost `try` with an `except` clause enclosing `body`.
  local function resolve_block(body, handling)
    for _, statement in ipairs(body) do
      local kind = statement.kind
      if kind == "Assign" then
        resolve_expression(statement.value)
        statement.symbol = scope[statement.name]
        if statement.annotation then
          statement.annotation = resolve_type(statement.annotation, module)
        end
      elseif kind == "FieldAssign" then
        resolve_expression(statement.value)
        local enum = enum_named(statement.object)
        if enum then
          diag.error(statement.span, "cannot assign to a member of enum '" .. enum.type_name .. "'")
        end
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
        resolve_block(statement.body, handling)
        if statement.else_body then
          resolve_block(statement.else_body, handling)
        end
      elseif kind == "While" then
        resolve_expression(statement.condition)
        resolve_block(statement.body, handling)
      elseif kind == "For" then
        resolve_expression(statement.iterable)
        statement.symbol = scope[statement.name]
        resolve_block(statement.body, handling)
      elseif kind == "Assert" then
        resolve_expression(statement.condition)
        if statement.message then
          resolve_expression(statement.message)
        end
      elseif kind == "Raise" then
        if statement.value then
          resolve_expression(statement.value)
        elseif not handling then
          diag.error(statement.span, "bare 'raise' is only allowed in an 'except' clause")
        end
        statement.try = handling
      elseif kind == "Try" then
        resolve_block(statement.body, handling)
        for _, handler in ipairs(statement.handlers) do
          handler.record = resolve_named(handler.class, module)
          if not handler.record.exception then
            diag.error(handler.class.span, "'" .. handler.record.name .. "' is not an exception class")
          end
          handler.symbol = handler.name and scope[handler.name]
          resolve_block(handler.body, statement)
        end
        if statement.finally_body then
          resolve_block(statement.finally_body, handling)
        end
      end
    end
  end

  resolve_block(fn.body)
end

-- Checks names that must be unique within a function's parameters or a
-- class's fields.
local function check_unique(items, what)
  local seen = {}
  for _, item in ipairs(items) do
    if seen[item.name] then
      diag.error(item.span, "duplicate " .. what .. " '" .. item.name .. "'")
    end
    seen[item.name] = true
  end
end

-- Collects one module's imports, functions, records, enums, and aliases, which share one
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
  for _, enum in ipairs(module.enums) do
    ordered[#ordered + 1] = enum
  end
  for _, alias in ipairs(module.aliases) do
    ordered[#ordered + 1] = alias
  end
  table.sort(ordered, function(a, b)
    return a.span.first < b.span.first
  end)

  -- An import takes its root name, which several qualified imports may share.
  module.declarations, module.imported, module.roots = {}, {}, {}
  local taken = {}
  for _, declaration in ipairs(ordered) do
    local import = declaration.kind == "Import"
    local name = import and declaration.root or declaration.name
    if builtins[name] then
      diag.error(declaration.span, "cannot redefine built-in function '" .. name .. "'")
    elseif exceptions[name] then
      diag.error(declaration.span, "cannot redefine built-in class '" .. name .. "'")
    end
    if import then
      local full = declaration.name
      for other in pairs(module.imported) do
        local short, long = other, full
        if #short > #long then
          short, long = long, short
        end
        if long:sub(1, #short + 1) == short .. "." then
          diag.error(declaration.span, "'" .. short .. "' is imported as a module and as a namespace")
        end
      end
      if module.imported[full] or taken[name] and not module.roots[name] then
        diag.error(declaration.span, "duplicate import '" .. full .. "'")
      end
    elseif taken[name] then
      local noun = declaration.kind == "Record" and "class" or declaration.kind:lower()
      diag.error(declaration.span, "duplicate " .. noun .. " '" .. name .. "'")
    end
    taken[name] = true
    if import then
      module.roots[name] = true
      module.imported[declaration.name] = modules_by_name[declaration.name] or stdlib.modules[declaration.name]
    else
      declaration.module = module
      module.declarations[name] = declaration
    end
    if declaration.kind == "Record" or declaration.kind == "Enum" or declaration.kind == "Alias" then
      declaration.type_name = module == entry and name or module.name .. "." .. name
    end
    if declaration.kind == "Record" then
      declaration.type = types.record(declaration)
    elseif declaration.kind == "Enum" then
      declaration.type = types.enum(declaration)
    end
  end
end

local literal_types = {
  Int = types.int,
  Float = types.float,
  String = types.str,
  Bool = types.bool,
  None = types.None,
}

-- Checks that the default of `decl`, a parameter or field, fits its type.
local function check_default(decl)
  local default = decl.default
  local type = literal_types[default.kind]
  if not types.assignable(decl.type, type) then
    diag.error(default.span, "expected " .. decl.type.name .. ", received " .. type.name)
  end
end

-- Binds `modules`, the entry module first. A test entry needs no `main`;
-- instead `entry.tests` lists its `test_*` functions by name.
function M.bind(modules, test)
  local entry = modules[1]
  local modules_by_name = {}
  for _, module in ipairs(modules) do
    modules_by_name[module.name or ""] = module
  end
  for _, module in ipairs(modules) do
    declare(module, modules_by_name, entry)
  end

  for _, module in ipairs(modules) do
    for _, enum in ipairs(module.enums) do
      check_unique(enum.members, "enum member")
    end
  end

  pending = {}
  for _, module in ipairs(modules) do
    for _, alias in ipairs(module.aliases) do
      resolve_alias(alias)
    end
  end
  -- A method's `self` has the type of its class.
  local function resolve_signature(fn, module)
    check_unique(fn.params, "parameter")
    for i, param in ipairs(fn.params) do
      param.type = fn.class and i == 1 and fn.class.type or resolve_type(param.type, module)
    end
    fn.return_type = resolve_type(fn.return_type, module)
  end
  for _, module in ipairs(modules) do
    for _, record in ipairs(module.records) do
      check_unique(record.fields, "field")
      check_unique(record.methods, "method")
      for _, field in ipairs(record.fields) do
        field.type = resolve_type(field.type, module)
      end
      for _, method in ipairs(record.methods) do
        for _, field in ipairs(record.fields) do
          if field.name == method.name then
            diag.error(method.span, "method '" .. method.name .. "' has the same name as a field")
          end
        end
        method.class, method.module = record, module
        resolve_signature(method, module)
      end
    end
    for _, fn in ipairs(module.functions) do
      resolve_signature(fn, module)
    end
  end
  force_pending()
  for _, module in ipairs(modules) do
    for _, record in ipairs(module.records) do
      for _, field in ipairs(record.fields) do
        if field.default then
          check_default(field)
        end
      end
    end
    for _, fn in ipairs(M.functions(module)) do
      for _, param in ipairs(fn.params) do
        if param.default then
          check_default(param)
        end
      end
    end
  end

  if test then
    entry.tests = {}
    for _, fn in ipairs(entry.functions) do
      if fn.name:sub(1, 5) == "test_" then
        if #fn.params > 0 or fn.return_type ~= types.None then
          diag.error(fn.span, "test function '" .. fn.name .. "' must take no parameters and return None")
        end
        entry.tests[#entry.tests + 1] = fn
      end
    end
    table.sort(entry.tests, function(a, b)
      return a.name < b.name
    end)
  else
    local main = entry.declarations.main
    if not (main and main.kind == "Function") then
      diag.error(entry.span, "program has no main function")
    end
    if #main.params > 0 or main.return_type ~= types.None then
      diag.error(main.span, "main must take no parameters and return None")
    end
  end

  for _, module in ipairs(modules) do
    for _, fn in ipairs(M.functions(module)) do
      resolve_function(fn, collect_symbols(fn), module)
    end
  end
  force_pending()
end

return M
