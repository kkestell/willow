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
-- A nested function's scope falls back to `outer`, its enclosing scope.
local function collect_symbols(fn, outer)
  local scope = {}
  for _, param in ipairs(fn.params) do
    param.symbol = { name = param.name, span = param.span, param = true, owner = fn }
    scope[param.name] = param.symbol
  end

  -- `nonlocal` names rebind the enclosing function's variables, so assignments
  -- after the declaration make no local of their own.
  fn.locals, fn.nonlocal_pending = {}, {}
  ast.assignments(fn.body, function(node)
    if node.kind == "Nonlocal" then
      for _, n in ipairs(node.names) do
        local own, enclosing = scope[n.name], outer and outer[n.name]
        if own and own.param or not own and not enclosing then
          diag.error(n.span, "nonlocal '" .. n.name .. "' must name a variable of an enclosing function")
        elseif own and own ~= enclosing then
          diag.error(n.span, "'" .. n.name .. "' is used before its nonlocal declaration")
        end
        scope[n.name] = enclosing
        fn.nonlocal_pending[n.name] = true
      end
    elseif not scope[node.name] then
      local symbol = { name = node.name, span = node.span, owner = fn }
      scope[node.name] = symbol
      fn.locals[#fn.locals + 1] = symbol
    end
    -- A nested `def` names the function a call of the local reaches.
    if node.kind == "FunctionDef" then
      scope[node.name].def = node.fn
    end
  end)
  return setmetatable(scope, { __index = outer })
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

-- Returns the record, protocol, enum, alias, or `typing.Callable` that `ref`, a `{ name, module, span }` in a type,
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
  if not (kind == "Record" or kind == "Protocol" or kind == "Enum" or kind == "Alias" or kind == "Callable") then
    diag.error(ref.span, "unknown type '" .. (ref.module and ref.module .. "." or "") .. ref.name .. "'")
  end
  return declaration
end

-- Lazy list elements and dict values waiting to be resolved.
local pending = {}

-- The type parameters in scope where types are being resolved, by name.
local type_scope = {}

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
  elseif node.name == "tuple" then
    local names = {}
    for i, arg in ipairs(node.args) do
      names[i] = type_text(arg, module)
    end
    return "tuple[" .. (#names == 0 and "()" or table.concat(names, ", ")) .. "]"
  elseif SCALARS[node.name] then
    return node.name
  elseif not node.module and type_scope[node.name] then
    -- A generic alias's body names the type arguments it was given.
    return type_scope[node.name].name
  end
  local declaration, args = resolve_named(node, module), node.args
  if declaration.kind == "Callable" and args and #args == 2 and args[1].kind == "TypeList" then
    local names = {}
    for i, element in ipairs(args[1].elements) do
      names[i] = type_text(element, module)
    end
    return "typing.Callable[[" .. table.concat(names, ", ") .. "], " .. type_text(args[2], module) .. "]"
  elseif (declaration.kind == "Record" or declaration.kind == "Protocol" or declaration.kind == "Alias") and args then
    local names = {}
    for i, arg in ipairs(args) do
      names[i] = type_text(arg, module)
    end
    return declaration.type_name .. "[" .. table.concat(names, ", ") .. "]"
  end
  return declaration.type_name
end

local resolve_type

-- A lazy type keeps the type parameters in scope where it was written.
local function lazy(node, module)
  local t = { kind = "lazy", name = type_text(node, module), node = node, module = module, scope = type_scope }
  pending[#pending + 1] = t
  return t
end

-- Resolves every lazy type; resolving one may queue more.
local function force_pending()
  local outer = type_scope
  while #pending > 0 do
    local t = table.remove(pending)
    type_scope = t.scope
    t.type = resolve_type(t.node, t.module)
    type_scope = outer
  end
end

-- Puts the type parameters of `fn` in scope, making them on first use; returns
-- the scope to restore afterward.
local function enter_type_params(fn)
  local outer = type_scope
  if #(fn.type_params or {}) == 0 then
    return outer
  end
  local scope = setmetatable({}, { __index = outer })
  fn.typevars = fn.typevars or {}
  for i, param in ipairs(fn.type_params) do
    if scope[param.name] then
      diag.error(param.span, "type parameter '" .. param.name .. "' hides another type parameter")
    end
    fn.typevars[i] = fn.typevars[i] or types.typevar(param.name)
    scope[param.name] = fn.typevars[i]
  end
  type_scope = scope
  -- Bounds resolve with the parameters in scope.
  for i, param in ipairs(fn.type_params) do
    if param.bound and not fn.typevars[i].bound then
      local bound = resolve_type(param.bound, fn.module)
      if bound.kind ~= "record" then
        diag.error(param.bound.span, "a type parameter's bound must be a class or native type")
      end
      fn.typevars[i].bound = bound
    end
  end
  return outer
end

-- Whether method signatures are resolved, so that unions with protocol members
-- can be checked for overlap. Until then those checks wait in `waiting`.
local ready, waiting = false, {}

-- How many generic alias applications enclose each alias body's type scope.
local alias_depth = {}

-- The type generic alias `decl` gives `args`. Each argument list is resolved
-- once, so a recursive use through `list` or `dict` with the same arguments
-- finds it. A recursive use with growing arguments nests without end.
local function apply_alias(decl, args, span)
  decl.applications = decl.applications or {}
  local application
  for _, a in ipairs(decl.applications) do
    local all = true
    for i, arg in ipairs(args) do
      all = all and a.args[i] == arg
    end
    if all then
      application = a
      break
    end
  end
  if application and not application.type then
    diag.error(span, "alias '" .. decl.name .. "' expands to itself")
  elseif application then
    return application.type
  end
  local depth = (alias_depth[type_scope] or 0) + 1
  if depth > 100 then
    diag.error(span, "alias '" .. decl.name .. "' expands without end")
  end
  application = { args = args }
  decl.applications[#decl.applications + 1] = application
  local scope, names = {}, {}
  for i, param in ipairs(decl.type_params) do
    scope[param.name], names[i] = args[i], args[i].name
  end
  alias_depth[scope] = depth
  local outer = type_scope
  type_scope = scope
  local name = decl.value.kind == "UnionType" and decl.type_name .. "[" .. table.concat(names, ", ") .. "]" or nil
  application.type = resolve_type(decl.value, decl.module, name)
  type_scope = outer
  return application.type
end

-- Sets `decl.type` to the type alias `decl` names. Its list elements and dict
-- values are lazy, so only other positions can reach an alias being resolved.
local function resolve_alias(decl)
  if #(decl.type_params or {}) > 0 then
    -- Applying the alias to its own parameters checks its body once.
    if not decl.typevars then
      local outer = enter_type_params(decl)
      type_scope = outer
      apply_alias(decl, decl.typevars, decl.span)
    end
    return nil
  end
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
    -- A type argument substituted for a parameter flattens into the union,
    -- dropping members the union already has.
    local substituted = false
    for _, member in ipairs(node.members) do
      local named = member.kind == "Type" and not member.module and type_scope[member.name]
      substituted = substituted or named and named.kind ~= "typevar"
    end
    local members, spans, protocol = {}, {}, false
    for _, member in ipairs(node.members) do
      for _, m in ipairs(types.members(resolve_type(member, module))) do
        local held = false
        for _, other in ipairs(substituted and members or {}) do
          held = held or types.same(other, m)
        end
        if not held then
          members[#members + 1], spans[#members + 1] = m, member.span
          protocol = protocol or m.kind == "protocol"
        end
      end
    end
    local function check_overlap()
      for i = 2, #members do
        local message = types.conflict({ unpack(members, 1, i - 1) }, members[i])
        if message then
          diag.error(spans[i], message)
        end
      end
    end
    if ready or not protocol then
      check_overlap()
    else
      waiting[#waiting + 1] = check_overlap
    end
    local union = types.union(members, name)
    for _, m in ipairs(members) do
      if m.kind == "typevar" and not (#members == 2 and types.has(union, "None")) then
        diag.error(node.span, "a type parameter can be in a union only with None")
      end
    end
    return union
  elseif node.name == "list" then
    return types.list(lazy(node.args[1], module))
  elseif node.name == "dict" then
    local key = resolve_type(node.args[1], module)
    if not types.is_key(key) then
      diag.error(node.args[1].span, "dictionary keys must be int, str, or an enum")
    end
    return types.dict(key, lazy(node.args[2], module))
  elseif node.name == "tuple" then
    local elements = {}
    for i, arg in ipairs(node.args) do
      elements[i] = resolve_type(arg, module)
    end
    return types.tuple(elements)
  elseif SCALARS[node.name] then
    return SCALARS[node.name]
  elseif not node.module and type_scope[node.name] then
    if node.args then
      diag.error(node.span, "type parameter '" .. node.name .. "' does not take type arguments")
    end
    return type_scope[node.name]
  end
  local declaration, args = resolve_named(node, module), node.args
  if declaration.kind == "Callable" then
    if not (args and #args == 2 and args[1].kind == "TypeList" and args[2].kind ~= "TypeList") then
      diag.error(node.span, "typing.Callable expects a list of parameter types and a return type")
    end
    local params = {}
    for i, element in ipairs(args[1].elements) do
      params[i] = resolve_type(element, module)
    end
    return types.callable(params, resolve_type(args[2], module))
  elseif declaration.typevars or #(declaration.type_params or {}) > 0 then
    -- A generic class or alias takes all of its type arguments.
    local count = #declaration.type_params
    if not args then
      diag.error(node.span, "type '" .. declaration.type_name .. "' needs type arguments")
    elseif #args ~= count then
      diag.error(node.span, "'" .. declaration.type_name .. "' expects " .. count
        .. (count == 1 and " type argument" or " type arguments") .. ", received " .. #args)
    end
    local resolved = {}
    for i, arg in ipairs(args) do
      if arg.kind == "TypeList" then
        diag.error(arg.span, "expected a type")
      end
      resolved[i] = resolve_type(arg, module)
      local unsatisfied = declaration.typevars and types.unsatisfied(declaration.typevars[i], resolved[i])
      if unsatisfied then
        diag.error(arg.span, unsatisfied)
      end
    end
    if declaration.kind == "Alias" then
      return apply_alias(declaration, resolved, node.span)
    elseif declaration.kind == "Protocol" then
      return types.protocol(declaration, resolved)
    end
    return types.generic(declaration, resolved)
  elseif args then
    diag.error(node.span, "type '" .. declaration.type_name .. "' does not take type arguments")
  end
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

-- The enum that `node` names as `E` or `module.E` in `module` when no name in
-- `scope` shadows it, or nil.
local function enum_named(node, module, scope)
  local path, root = qualified_name(node)
  if not path or scope[root] then
    return nil
  end
  local declaration
  if path == root then
    declaration = module.declarations[path]
  elseif module.roots[root] then
    local prefix, name = path:match("^(.*)%.([^.]*)$")
    local imported = module.imported[prefix]
    declaration = imported and lookup(module, imported, name, node.span)
  end
  if declaration and declaration.kind == "Enum" then
    return declaration
  end
end

-- Rewrites `node`, a `Field` on enum `enum`, into an `EnumMember`.
local function resolve_member(node, enum)
  local found = false
  for _, member in ipairs(enum.members) do
    found = found or member.name == node.name
  end
  if not found then
    diag.error(node.span, "enum '" .. enum.type_name .. "' has no member '" .. node.name .. "'")
  end
  node.kind, node.enum, node.object = "EnumMember", enum, nil
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

local literal_types = {
  Int = types.int,
  Float = types.float,
  String = types.str,
  Bool = types.bool,
  None = types.None,
}

-- The type of `default`, a default in `module`, which is also recorded as
-- `default.type` for lowering; resolves its enum members.
-- Parameters and locals cannot shadow an enum named in a default.
local function default_type(default, module)
  if default.kind == "Field" then
    local enum = enum_named(default.object, module, {})
    if not enum then
      diag.error(default.object.span, "unknown enum '" .. qualified_name(default.object) .. "'")
    end
    resolve_member(default, enum)
    default.type = enum.type
  elseif default.kind == "TupleDisplay" then
    local elements = {}
    for i, element in ipairs(default.elements) do
      elements[i] = default_type(element, module)
    end
    default.type = types.tuple(elements)
  else
    default.type = literal_types[default.kind]
  end
  return default.type
end

-- Checks that the default of `decl`, a parameter or field of `module`, fits
-- its type.
local function check_default(decl, module)
  local default = decl.default
  local type = default_type(default, module)
  if not types.assignable(decl.type, type) then
    diag.error(default.span, "expected " .. decl.type.name .. ", received " .. type.name)
  end
end


-- Resolves the parameter and return types of `fn`. A method's `self` has the
-- type of its class.
local function resolve_signature(fn, module)
  -- A method sees its class's type parameters and then its own.
  local outer = type_scope
  if fn.class then
    enter_type_params(fn.class)
  end
  enter_type_params(fn)
  check_unique(fn.params, "parameter")
  for i, param in ipairs(fn.params) do
    param.type = fn.class and i == 1 and fn.class.self_type or resolve_type(param.type, module)
  end
  fn.return_type = resolve_type(fn.return_type, module)
  type_scope = outer
end

-- The declaration kinds that name no function or class to call.
local CANNOT_CALL = { Alias = true, Enum = true, Callable = true, Protocol = true }

local function is_generic(declaration)
  return declaration and (declaration.kind == "Function" or declaration.kind == "Record")
    and #(declaration.type_params or {}) > 0
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

  -- Makes `node` a function value of `declaration`, or reports why a
  -- declaration named `name` cannot be a value.
  local function declared_value(node, declaration, name)
    if declaration.kind == "Function" then
      -- A qualified name reaches the function even where a local hides it.
      node.qualified = node.kind == "Field"
      node.kind, node.target, node.object = "FunctionValue", declaration, nil
    elseif declaration.kind == "Record" then
      diag.error(node.span, "class '" .. name .. "' cannot be used as a value")
    elseif declaration.kind == "Builtin" and declaration.params then
      -- Check gives it the signature of an expected callable type.
      node.kind, node.target, node.name, node.object = "BuiltinValue", declaration, name, nil
    elseif declaration.kind == "Builtin" then
      diag.error(node.span, "function '" .. name .. "' cannot be used as a value")
    else
      diag.error(node.span, declaration.kind:lower() .. " '" .. name .. "' cannot be used as a value")
    end
  end

  -- Records that `symbol`, a variable of an enclosing function, is captured by
  -- `fn` and by each function between `fn` and the symbol's owner.
  local function capture(symbol, span)
    symbol.captured = true
    local f = fn
    while f ~= symbol.owner do
      f.captures = f.captures or {}
      local found = false
      for _, c in ipairs(f.captures) do
        found = found or c.symbol == symbol
      end
      if not found then
        f.captures[#f.captures + 1] = { symbol = symbol, span = span }
      end
      f = f.parent
    end
  end

  -- Grows with each call resolved in this function, not in nested ones.
  local calls = 0

  -- The prefix of the names of functions nested in `fn`.
  local enclosing_name = fn.type_name or fn.class.type_name .. "." .. fn.name

  local function resolve_expression(node)
    local kind = node.kind
    if kind == "Call" or kind == "CallValue" or kind == "MethodCall" then
      calls = calls + 1
    end
    if kind == "Name" and not scope[node.name] and (declarations[node.name] or builtins[node.name]) then
      declared_value(node, declarations[node.name] or builtins[node.name], node.name)
    elseif kind == "Name" then
      if fn.nonlocal_pending[node.name] then
        diag.error(node.span, "'" .. node.name .. "' is used before its nonlocal declaration")
      end
      node.symbol = scope[node.name]
      if not node.symbol then
        if roots[node.name] then
          diag.error(node.span, "module '" .. node.name .. "' cannot be used as a value")
        elseif exceptions[node.name] then
          diag.error(node.span, "class '" .. node.name .. "' cannot be used as a value")
        end
        diag.error(node.span, "unknown name '" .. node.name .. "'")
      end
      if is_generic(node.symbol.def) and not node.is_callee then
        diag.error(node.span, "generic function '" .. node.name .. "' cannot be used as a value")
      end
      if node.symbol.owner ~= fn then
        capture(node.symbol, node.span)
      end
    elseif kind == "Call" and scope[node.name] then
      -- A local hides a declaration of the same name, so this calls its value.
      node.kind, node.callee = "CallValue", ast.node("Name", node.span, { name = node.name })
      node.name = nil
      resolve_expression(node)
    elseif kind == "SpecializedCall" then
      local callee, name, symbol, declaration = node.callee
      if callee.kind == "Name" then
        name, symbol = callee.name, scope[callee.name]
        declaration = not symbol and (declarations[name] or builtins[name])
      elseif module_path(callee.object) and imports[module_path(callee.object)] then
        local path = module_path(callee.object)
        name, declaration = path .. "." .. callee.name, lookup(module, imports[path], callee.name, callee.span)
      end
      if is_generic(declaration) or symbol and is_generic(symbol.def) then
        for i, arg in ipairs(node.type_args) do
          node.type_args[i] = resolve_type(arg, module)
        end
        node.index, node.index_error = nil, nil
        if symbol then
          node.kind = "CallValue"
        else
          node.kind, node.name, node.target, node.callee = "Call", name, declaration, nil
        end
      else
        -- An index followed by a call, as in `handlers[i](x)`.
        if declaration then
          diag.error(callee.span, "'" .. name .. "' is not generic")
        elseif not node.index then
          diag.raise(node.index_error)
        end
        node.kind, node.callee, node.type_args, node.index = "CallValue", node.index, nil, nil
      end
      resolve_expression(node)
    elseif kind == "Specialized" then
      -- A generic function specialized as a value, or else an index.
      local callee, declaration = node.callee
      if callee.kind == "Name" then
        declaration = not scope[callee.name] and declarations[callee.name]
      elseif module_path(callee.object) and imports[module_path(callee.object)] then
        declaration = lookup(module, imports[module_path(callee.object)], callee.name, callee.span)
      end
      if declaration and declaration.kind == "Function" and is_generic(declaration) then
        for i, arg in ipairs(node.type_args) do
          node.type_args[i] = resolve_type(arg, module)
        end
        node.kind, node.target, node.qualified, node.callee = "FunctionValue", declaration, callee.kind == "Field", nil
        node.index, node.index_error = nil, nil
      else
        local index = node.index
        if not index then
          diag.raise(node.index_error)
        end
        node.kind, node.span, node.object, node.index = "Index", index.span, index.object, index.index
        node.callee, node.type_args, node.index_error = nil, nil, nil
        resolve_expression(node)
      end
    elseif kind == "Lambda" then
      -- A lambda is a nested function whose body returns its expression.
      check_unique(node.params, "parameter")
      node.fn = {
        kind = "Function", name = "<lambda>", params = node.params, span = node.span,
        body = { ast.node("Return", node.span, { value = node.body }) },
        parent = fn, module = module, type_name = enclosing_name .. ".<lambda>",
      }
      resolve_function(node.fn, collect_symbols(node.fn, scope), module)
    elseif kind == "CallValue" then
      node.callee.is_callee = true
      resolve_expression(node.callee)
      for _, arg in ipairs(node.args) do
        resolve_expression(arg)
      end
    elseif kind == "Call" then
      -- A specialized call of a qualified name already has its target.
      node.target = node.target or declarations[node.name] or builtins[node.name] or exceptions[node.name]
      if not node.target then
        diag.error(node.span, "unknown function '" .. node.name .. "'")
      elseif CANNOT_CALL[node.target.kind] then
        diag.error(node.span, node.target.kind:lower() .. " '" .. node.name .. "' cannot be called")
      end
      for _, arg in ipairs(node.args) do
        resolve_expression(arg)
      end
    elseif kind == "MethodCall" and enum_named(node.object, module, scope) then
      local enum = enum_named(node.object, module, scope)
      diag.error(node.span, "enum '" .. enum.type_name .. "' has no method '" .. node.name .. "'")
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
      if CANNOT_CALL[node.target.kind] then
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
      if not class.module and type_scope[class.name] then
        diag.error(class.span, "type parameter '" .. class.name .. "' cannot be used in isinstance")
      end
      if class.module or not SCALARS[class.name] and class.name ~= "list" and class.name ~= "dict"
        and class.name ~= "tuple" then
        local declaration = resolve_named(class, module)
        if declaration.kind == "Alias" then
          diag.error(class.span, "alias '" .. class.name .. "' cannot be used in isinstance")
        elseif declaration.kind == "Callable" then
          diag.error(class.span, "typing.Callable cannot be used in isinstance")
        elseif declaration.kind == "Protocol" then
          diag.error(class.span, "protocol '" .. class.name .. "' cannot be used in isinstance")
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
    elseif kind == "Field" and enum_named(node.object, module, scope) then
      resolve_member(node, enum_named(node.object, module, scope))
    elseif kind == "Field" and module_path(node.object) and imports[module_path(node.object)] then
      local path = module_path(node.object)
      declared_value(node, lookup(module, imports[path], node.name, node.span), path .. "." .. node.name)
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
    elseif kind == "ListDisplay" or kind == "TupleDisplay" then
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

  local function resolve_targets(pattern)
    if pattern.kind == "Name" then
      pattern.symbol = scope[pattern.name]
    else
      for _, element in ipairs(pattern.elements) do
        resolve_targets(element)
      end
    end
  end

  -- `handling` is the innermost `try` with an `except` clause enclosing `body`.
  local function resolve_block(body, handling)
    for _, statement in ipairs(body) do
      local kind = statement.kind
      if kind == "Unpack" then
        resolve_expression(statement.value)
        resolve_targets(statement.pattern)
      elseif kind == "Assign" then
        resolve_expression(statement.value)
        statement.symbol = scope[statement.name]
        if statement.annotation then
          statement.annotation = resolve_type(statement.annotation, module)
        end
      elseif kind == "Nonlocal" then
        for _, n in ipairs(statement.names) do
          fn.nonlocal_pending[n.name] = nil
          capture(scope[n.name], n.span)
        end
      elseif kind == "FunctionDef" then
        local nested = statement.fn
        nested.parent, nested.module = fn, module
        nested.type_name = enclosing_name .. "." .. nested.name
        resolve_signature(nested, module)
        force_pending()
        for _, param in ipairs(nested.params) do
          if param.default then
            check_default(param, module)
          end
        end
        nested.value_type = types.func(nested)
        statement.symbol = scope[statement.name]
        resolve_function(nested, collect_symbols(nested, scope), module)
      elseif kind == "FieldAssign" then
        resolve_expression(statement.value)
        local enum = enum_named(statement.object, module, scope)
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
        -- `calls` records whether a call can run before a later iteration.
        local before = calls
        resolve_expression(statement.condition)
        resolve_block(statement.body, handling)
        statement.calls = calls ~= before
      elseif kind == "For" then
        resolve_expression(statement.iterable)
        if statement.pattern then
          resolve_targets(statement.pattern)
        else
          statement.symbol = scope[statement.name]
        end
        local before = calls
        resolve_block(statement.body, handling)
        statement.calls = calls ~= before
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

  local outer_types = type_scope
  if fn.class then
    enter_type_params(fn.class)
  end
  enter_type_params(fn)
  resolve_block(fn.body)
  type_scope = outer_types
end

-- Collects one module's imports, functions, records, protocols, enums, and aliases, which share one
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
  for _, protocol in ipairs(module.protocols) do
    ordered[#ordered + 1] = protocol
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
    if not import then
      declaration.type_name = module == entry and name or module.name .. "." .. name
    end
    if declaration.kind == "Record" then
      declaration.type = types.record(declaration)
      declaration.self_type = declaration.type
      if #declaration.type_params > 0 then
        if declaration.exception then
          diag.error(declaration.type_params[1].span, "exception classes cannot be generic")
        end
        -- Methods see the class as specialized by its own type parameters.
        declaration.typevars = {}
        for i, param in ipairs(declaration.type_params) do
          declaration.typevars[i] = types.typevar(param.name)
        end
        declaration.self_type = types.generic(declaration, declaration.typevars)
      end
    elseif declaration.kind == "Protocol" then
      declaration.type = types.protocol(declaration)
      declaration.self_type = declaration.type
      if #declaration.type_params > 0 then
        declaration.typevars = {}
        for i, param in ipairs(declaration.type_params) do
          declaration.typevars[i] = types.typevar(param.name)
        end
        declaration.self_type = types.protocol(declaration, declaration.typevars)
      end
    elseif declaration.kind == "Enum" then
      declaration.type = types.enum(declaration)
    elseif declaration.kind == "Function" then
      declaration.value_type = types.func(declaration)
    end
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
  type_scope, ready, waiting = {}, false, {}
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
  for _, module in ipairs(modules) do
    for _, record in ipairs(module.records) do
      check_unique(record.fields, "field")
      check_unique(record.methods, "method")
      local outer = enter_type_params(record)
      for _, field in ipairs(record.fields) do
        field.type = resolve_type(field.type, module)
      end
      type_scope = outer
      for _, method in ipairs(record.methods) do
        for _, field in ipairs(record.fields) do
          if field.name == method.name then
            diag.error(method.span, "method '" .. method.name .. "' has the same name as a field")
          end
        end
        method.class, method.module = record, module
        method.value_type = types.func(method, true)
        resolve_signature(method, module)
      end
    end
    for _, protocol in ipairs(module.protocols) do
      check_unique(protocol.methods, "method")
      local outer = enter_type_params(protocol)
      type_scope = outer
      for _, method in ipairs(protocol.methods) do
        method.class, method.module = protocol, module
        resolve_signature(method, module)
      end
    end
    for _, fn in ipairs(module.functions) do
      resolve_signature(fn, module)
    end
  end
  force_pending()
  ready = true
  for _, check_overlap in ipairs(waiting) do
    check_overlap()
  end
  for _, module in ipairs(modules) do
    for _, record in ipairs(module.records) do
      for _, field in ipairs(record.fields) do
        if field.default then
          check_default(field, module)
        end
      end
    end
    for _, fn in ipairs(M.functions(module)) do
      for _, param in ipairs(fn.params) do
        if param.default then
          check_default(param, module)
        end
      end
    end
    for _, protocol in ipairs(module.protocols) do
      for _, method in ipairs(protocol.methods) do
        for _, param in ipairs(method.params) do
          if param.default then
            check_default(param, module)
          end
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
