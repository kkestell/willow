-- Resolves names and collects function signatures, annotating the tree in place.
local diag = require("compiler.diag")
local types = require("compiler.types")

local M = {}

local builtins = {
  print = { kind = "Builtin", name = "print" },
  int = { kind = "Builtin", name = "int" },
  float = { kind = "Builtin", name = "float" },
  str = { kind = "Builtin", name = "str" },
  len = { kind = "Builtin", name = "len" },
  range = { kind = "Builtin", name = "range" },
  input = { kind = "Builtin", name = "input" },
  ord = { kind = "Builtin", name = "ord" },
  chr = { kind = "Builtin", name = "chr" },
  isinstance = { kind = "Builtin", name = "isinstance" },
  sorted = { kind = "Builtin", name = "sorted" },
}

-- The compiler-provided modules. They have no source: their declarations are
-- built-in targets and records, and a program's own `sys.wlo`, `fs.wlo`, or
-- `time.wlo` shadows them.
local function provided(name, functions, records)
  local declarations = records or {}
  for function_name in functions:gmatch("%S+") do
    declarations[function_name] = { kind = "Builtin", name = function_name }
  end
  return { name = name, declarations = declarations }
end

local stat = {
  kind = "Record",
  name = "Stat",
  type_name = "fs.Stat",
  fields = {
    { name = "kind", type = types.str },
    { name = "size", type = types.int },
    { name = "modified", type = types.float },
  },
}
stat.type = types.record(stat)

M.modules = {
  sys = provided("sys", "args eprint exit getenv environ getcwd"),
  fs = provided("fs", "read_file write_file join basename dirname listdir stat exists mkdir remove rmdir rename",
    { Stat = stat }),
  time = provided("time", "time monotonic sleep utc"),
}
M.stat = stat

-- The built-in exception classes, records with only a `message` field.
local exceptions = {}
M.exceptions = exceptions
for name in ("Exception AssertionError OverflowError ZeroDivisionError ValueError IndexError KeyError RuntimeError OSError TimeoutError"):gmatch("%S+") do
  exceptions[name] = {
    kind = "Record",
    name = name,
    type_name = name,
    exception = true,
    fields = { { name = "message", type = types.str } },
  }
  exceptions[name].type = types.record(exceptions[name])
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
      elseif kind == "Try" then
        walk(statement.body)
        for _, handler in ipairs(statement.handlers) do
          if handler.name and not scope[handler.name] then
            local symbol = { name = handler.name, span = handler.span }
            scope[handler.name] = symbol
            fn.locals[#fn.locals + 1] = symbol
          end
          walk(handler.body)
        end
        if statement.finally_body then
          walk(statement.finally_body)
        end
      end
    end
  end
  walk(fn.body)
  return scope
end

local SCALARS = { int = types.int, float = types.float, bool = types.bool, str = types.str, None = types.None }

-- Returns declaration `name` of `module` as seen from module `from`. Names that
-- begin with `_` are private to their module.
local function lookup(from, module, name, span)
  local declaration = module.declarations[name]
  if not declaration then
    diag.error(span, "module '" .. module.name .. "' has no function, record, or alias '" .. name .. "'")
  end
  if name:sub(1, 1) == "_" and module ~= from then
    diag.error(span, "'" .. name .. "' is private to module '" .. module.name .. "'")
  end
  return declaration
end

-- Returns the record or alias that `ref`, a `{ name, module, span }` in a type,
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
  if not (declaration and (declaration.kind == "Record" or declaration.kind == "Alias")) then
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
        elseif declaration and declaration.kind == "Record" or exceptions[node.name] then
          diag.error(node.span, "record '" .. node.name .. "' cannot be used as a value")
        elseif declaration and declaration.kind == "Alias" then
          diag.error(node.span, "alias '" .. node.name .. "' cannot be used as a value")
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
      elseif node.target.kind == "Alias" then
        diag.error(node.span, "alias '" .. node.name .. "' cannot be called")
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
      if node.target.kind == "Alias" then
        diag.error(node.span, "alias '" .. node.name .. "' cannot be called")
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

-- Collects one module's imports, functions, records, and aliases, which share one
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
  for _, alias in ipairs(module.aliases) do
    ordered[#ordered + 1] = alias
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
    elseif exceptions[name] then
      diag.error(declaration.span, "cannot redefine built-in class '" .. name .. "'")
    end
    if taken[name] then
      diag.error(declaration.span, "duplicate " .. declaration.kind:lower() .. " '" .. name .. "'")
    end
    taken[name] = true
    if declaration.kind == "Import" then
      module.imported[name] = modules_by_name[name] or M.modules[name]
    else
      declaration.module = module
      module.declarations[name] = declaration
    end
    if declaration.kind == "Record" or declaration.kind == "Alias" then
      declaration.type_name = module == entry and name or module.name .. "." .. name
    end
    if declaration.kind == "Record" then
      declaration.type = types.record(declaration)
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

  pending = {}
  for _, module in ipairs(modules) do
    for _, alias in ipairs(module.aliases) do
      resolve_alias(alias)
    end
  end
  for _, module in ipairs(modules) do
    for _, record in ipairs(module.records) do
      check_unique(record.fields, "field")
      for _, field in ipairs(record.fields) do
        field.type = resolve_type(field.type, module)
      end
    end
    for _, fn in ipairs(module.functions) do
      check_unique(fn.params, "parameter")
      for _, param in ipairs(fn.params) do
        param.type = resolve_type(param.type, module)
      end
      fn.return_type = resolve_type(fn.return_type, module)
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
    for _, fn in ipairs(module.functions) do
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
    for _, fn in ipairs(module.functions) do
      resolve_function(fn, collect_symbols(fn), module)
    end
  end
  force_pending()
end

return M
