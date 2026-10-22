-- Type objects. Every type has a `kind` and a display `name`. Scalars,
-- records, and enums are single objects compared by identity.
local M = {}

for name in ("int float bool str None bytes"):gmatch("%S+") do
  M[name] = { kind = name, name = name }
end

local SCALARS = { int = true, float = true, bool = true, str = true, None = true, bytes = true, enum = true }
local PRINTABLE = { int = true, float = true, bool = true, str = true, None = true, enum = true }

function M.list(element)
  return { kind = "list", element = element, name = "list[" .. element.name .. "]" }
end

function M.dict(key, value)
  return { kind = "dict", key = key, value = value, name = "dict[" .. key.name .. ", " .. value.name .. "]" }
end

function M.tuple(elements)
  local names = {}
  for i, element in ipairs(elements) do
    names[i] = element.name
  end
  local name = #elements == 0 and "()" or table.concat(names, ", ")
  return { kind = "tuple", elements = elements, name = "tuple[" .. name .. "]" }
end

function M.record(decl)
  return { kind = "record", record = decl, name = decl.type_name }
end

-- The specialization of generic class `decl` with type arguments `args`.
-- Specializations are compared by their arguments, so they are invariant.
function M.generic(decl, args)
  local names = {}
  for i, arg in ipairs(args) do
    names[i] = arg.name
  end
  return { kind = "record", record = decl, args = args, name = decl.type_name .. "[" .. table.concat(names, ", ") .. "]" }
end

-- A protocol, or with `args` a generic protocol's specialization, compared by
-- its arguments like a generic class.
function M.protocol(decl, args)
  local names = {}
  for i, arg in ipairs(args or {}) do
    names[i] = arg.name
  end
  local name = args and decl.type_name .. "[" .. table.concat(names, ", ") .. "]" or decl.type_name
  return { kind = "protocol", protocol = decl, args = args, name = name }
end

-- The generic class or protocol `t` specializes, or nil.
function M.generic_decl(t)
  return t.args and (t.record or t.protocol)
end

-- The substitution a specialization gives its declaration's type parameters.
function M.record_map(t)
  local map = {}
  for i, typevar in ipairs(t.args and (t.record or t.protocol).typevars or {}) do
    map[typevar] = t.args[i]
  end
  return map
end

-- `(A, B) -> R`: a function taking exactly those positional arguments. It is
-- compared by structure.
function M.callable(params, result)
  local names = {}
  for i, param in ipairs(params) do
    names[i] = param.name
  end
  return {
    kind = "callable", params = params, result = result,
    name = "(" .. table.concat(names, ", ") .. ") -> " .. result.name,
  }
end

-- The type of a declared function as a value, retaining its full call signature.
-- A `bound` method keeps its receiver, so calls skip its `self` parameter.
-- A generic receiver specializes the signature and participates in type identity.
function M.func(decl, bound, receiver)
  local name = bound and (receiver and receiver.name or decl.class.type_name) .. "." .. decl.name or decl.type_name
  local signature = receiver and M.method(receiver, decl.name)
  return {
    kind = "function", fn = decl, bound = bound, name = "function " .. name,
    receiver = receiver, params = signature and signature.params, result = signature and signature.result,
  }
end

-- The parameters a call through function type `t` binds.
function M.params(t)
  return t.params or (t.bound and { unpack(t.fn.params, 2) } or t.fn.params)
end

function M.result(t)
  return t.result or t.fn.return_type
end

-- A type parameter as its declaration's body sees it: compared by identity,
-- with no operations beyond storing, passing, and returning.
function M.typevar(name)
  return { kind = "typevar", name = name }
end

function M.enum(decl)
  return { kind = "enum", enum = decl, name = decl.type_name }
end

-- Dictionary keys are ints, strs, or members of one enum.
function M.is_key(t)
  return t == M.int or t == M.str or t.kind == "enum"
end

-- Bind makes list elements and dict values lazy, filling in `type` once every
-- alias is resolved, so that aliases may refer to themselves inside them.
function M.expand(t)
  if t.kind == "lazy" then
    return t.type
  end
  return t
end

function M.members(t)
  return t.kind == "union" and t.members or { t }
end

-- Flattens union members; one member is returned as is.
function M.union(members, name)
  local flat, names = {}, {}
  for _, member in ipairs(members) do
    for _, m in ipairs(M.members(member)) do
      flat[#flat + 1] = m
      -- A callable's result would otherwise absorb the members after it.
      names[#names + 1] = m.kind == "callable" and "(" .. m.name .. ")" or m.name
    end
  end
  if #flat == 1 then
    return flat[1]
  end
  return { kind = "union", members = flat, name = name or table.concat(names, " | ") }
end

function M.has(t, kind)
  for _, m in ipairs(M.members(t)) do
    if m.kind == kind then
      return true
    end
  end
  return false
end

function M.optional(t)
  return t.kind == "union" and M.has(t, "None")
end

function M.printable(t)
  for _, m in ipairs(M.members(t)) do
    if not PRINTABLE[m.kind] then
      return false
    end
  end
  return true
end

-- Whether `==` applies: every member is printable, bytes, or a tuple whose
-- positions are comparable.
function M.comparable(t)
  for _, m in ipairs(M.members(t)) do
    if m.kind == "tuple" then
      for _, element in ipairs(m.elements) do
        if not M.comparable(element) then
          return false
        end
      end
    elseif not SCALARS[m.kind] then
      return false
    end
  end
  return true
end

-- Whether `<` and the other orderings apply: both are the same ordered scalar
-- type, or tuples of equal arity whose positions are ordered.
function M.ordered(a, b)
  if a.kind == "tuple" and b.kind == "tuple" and #a.elements == #b.elements then
    for i, element in ipairs(a.elements) do
      if not M.ordered(element, b.elements[i]) then
        return false
      end
    end
    return true
  end
  return a == b and (a == M.int or a == M.float or a == M.str)
end

-- In a type with both int and float members, floats are boxed at run time so
-- that they differ from ints.
function M.boxed(t)
  return M.has(t, "int") and M.has(t, "float")
end

-- Union members are matched by kind, or by declaration for records, enums,
-- and functions.
local function key(t)
  return t.record or t.enum or t.fn or t.protocol or (t.kind == "typevar" and t) or t.kind
end

-- `assumed` holds pairs already being compared, so recursive types terminate.
local function same(a, b, assumed)
  a, b = M.expand(a), M.expand(b)
  if a == b then
    return true
  end
  if a.kind == "function" and b.kind == "function" and a.receiver and b.receiver then
    return a.fn == b.fn and same(a.receiver, b.receiver, assumed)
  end
  if a.kind ~= b.kind
    or (a.kind == "record" or a.kind == "protocol") and not (a.args and b.args and M.generic_decl(a) == M.generic_decl(b))
    or a.kind == "function" or a.kind == "typevar" or SCALARS[a.kind] then
    return false
  end
  assumed[a] = assumed[a] or {}
  if assumed[a][b] then
    return true
  end
  assumed[a][b] = true
  if a.kind == "list" then
    return same(a.element, b.element, assumed)
  elseif a.kind == "dict" then
    return same(a.key, b.key, assumed) and same(a.value, b.value, assumed)
  elseif a.kind == "tuple" or a.kind == "callable" or a.kind == "record" or a.kind == "protocol" then
    local x, y = a.elements or a.params or a.args, b.elements or b.params or b.args
    if #x ~= #y or a.kind == "callable" and not same(a.result, b.result, assumed) then
      return false
    end
    for i, element in ipairs(x) do
      if not same(element, y[i], assumed) then
        return false
      end
    end
    return true
  end
  if #a.members ~= #b.members then
    return false
  end
  for _, m in ipairs(a.members) do
    local found = false
    for _, n in ipairs(b.members) do
      if key(m) == key(n) then
        found = same(m, n, assumed)
        break
      end
    end
    if not found then
      return false
    end
  end
  return true
end

function M.same(a, b)
  return same(a, b, {})
end

-- Whether a value of `source`, a function or callable, can serve callable
-- `target`: it accepts the target's positional arguments, any parameters past
-- them have defaults, and its result fits the target's.
local function serves(target, source)
  local params, result = source.params, source.result
  if source.kind == "function" then
    params, result = {}, M.result(source)
    for i, param in ipairs(M.params(source)) do
      if i <= #target.params and param.keyword_only or i > #target.params and not param.default then
        return false
      end
      params[i] = param.type
    end
  elseif source.kind ~= "callable" or #params ~= #target.params then
    return false
  end
  if #params < #target.params then
    return false
  end
  for i, param in ipairs(target.params) do
    if not M.assignable(params[i], param) then
      return false
    end
  end
  return M.assignable(target.result, result)
end

-- The signature of method `name` on `t`, a class, native type, or protocol,
-- with `t`'s type arguments substituted, or nil. `params` lists the
-- parameters after `self` as `{ name, type, default, keyword_only, generic }`;
-- a native method without `names` has positional-only parameters. `generic`,
-- and `result_generic` for the result, mark declared types that mention a type
-- parameter. A generic method has no single signature, so it is left out.
function M.method(t, name)
  local decl = t.record or t.protocol
  if not decl then
    -- Built-in collections, strings, and bytes have an `iter` method.
    local item = name == "iter" and M.iteration_item(t)
    return item and { params = {}, result = M.iterator(item), result_generic = true }
  elseif decl.native then
    local method = decl.native_methods[name]
    if not method then
      return nil
    end
    local params = {}
    for i, type in ipairs(method.params) do
      params[i] = {
        name = method.names and method.names[i], type = type, default = method.defaults and method.defaults[i],
        generic = M.mentions(type),
      }
    end
    return { params = params, result = method.result, result_generic = M.mentions(method.result) }
  end
  for _, method in ipairs(decl.methods) do
    if method.name == name and not method.typevars then
      local map, params = M.record_map(t), {}
      for i = 2, #method.params do
        local param = method.params[i]
        params[i - 1] = {
          name = param.name, type = M.substitute(param.type, map), default = param.default,
          keyword_only = param.keyword_only, generic = M.mentions(param.type),
        }
      end
      return {
        params = params, result = M.substitute(method.return_type, map),
        result_generic = M.mentions(method.return_type),
      }
    end
  end
end

-- The index of the parameter of method signature `have` that serves each
-- parameter of protocol method `want`, matched by position and name or, for a
-- keyword-only parameter, by name, or nil when the parameters do not line up.
-- Every parameter of `have` left unmatched has a default.
function M.match(want, have)
  local indexes, used = {}, {}
  for i, param in ipairs(want.params) do
    local index
    for j, h in ipairs(have.params) do
      if h.name == param.name then
        index = j
      end
    end
    local h = index and have.params[index]
    if not h or not param.keyword_only and (index ~= i or h.keyword_only) or param.default and not h.default then
      return nil
    end
    indexes[i], used[index] = index, true
  end
  for j, h in ipairs(have.params) do
    if not used[j] and not h.default then
      return nil
    end
  end
  return indexes
end

local function member(t, kind)
  for _, m in ipairs(M.members(t)) do
    if m.kind == kind then
      return m
    end
  end
end

-- Whether a value of `from` changes representation to serve `to`, or the
-- other way around: a float boxed or unboxed, including in tuple positions,
-- tuple items copied for a protocol, and callable parameters and results.
function M.converts(from, to)
  from, to = M.expand(from), M.expand(to)
  if M.boxed(to) ~= M.boxed(from) and M.has(M.boxed(to) and from or to, "float") then
    return true
  end
  local source, target = member(from, "tuple"), member(to, "tuple")
  if source and target then
    for i, element in ipairs(source.elements) do
      if M.converts(element, target.elements[i]) then
        return true
      end
    end
  elseif source and member(to, "protocol") or target and member(from, "protocol") then
    -- A tuple serving a protocol holds its items in the item type's
    -- representation.
    local tuple = source or target
    local items = M.items(tuple)
    for _, element in ipairs(tuple.elements) do
      if M.converts(element, items) then
        return true
      end
    end
  end
  source, target = member(from, "callable"), member(to, "callable")
  if source and target then
    for i, param in ipairs(target.params) do
      if M.converts(param, source.params[i]) then
        return true
      end
    end
    return M.converts(source.result, target.result)
  end
  return false
end

-- Whether `t` holds a float whose representation a conversion could change.
local function has_float(t)
  t = M.expand(t)
  if t.kind == "float" then
    return true
  end
  for _, part in ipairs(t.kind == "union" and t.members or t.elements or t.params or {}) do
    if has_float(part) then
      return true
    end
  end
  return t.kind == "callable" and has_float(t.result)
end

-- Whether a protocol converter can carry values between a protocol method's
-- position of type `want` and the matching position `have` of the method that
-- serves it; each is generic when its declared type mentions a type parameter.
-- A converter is built from declared types, so it converts only where neither
-- is generic. A value reached through another protocol uses its own type's
-- converter, so between protocols nothing may convert, and a position generic
-- only in `want` cannot hold a float that converter may have changed.
local function representable(want, have, want_generic, have_generic, between)
  if between then
    return not M.converts(have, want) and not (want_generic and not have_generic and has_float(have))
  end
  return not ((want_generic or have_generic) and M.converts(have, want))
end

-- The items a built-in value of type `t` yields when iterated, or nil: list
-- elements, dictionary keys, one-code-point strings, octets, or tuple items.
function M.iteration_item(t)
  t = M.expand(t)
  if t.kind == "list" then
    return M.expand(t.element)
  elseif t.kind == "dict" then
    return t.key
  elseif t == M.str then
    return M.str
  elseif t == M.bytes then
    return M.int
  elseif t.kind == "tuple" then
    return (M.items(t))
  end
end

-- Whether method signature `have` accepts every call protocol method `want`
-- permits, by position and by keyword, and returns a result `want` accepts.
-- `between` is true when `have` is a protocol's method.
local function compatible(want, have, between)
  local indexes = have and M.match(want, have)
  if not indexes then
    return false
  end
  for i, param in ipairs(want.params) do
    local h = have.params[indexes[i]]
    if not M.assignable(h.type, param.type)
      or not representable(param.type, h.type, param.generic, h.generic, between) then
      return false
    end
  end
  return M.assignable(want.result, have.result)
    and representable(want.result, have.result, want.result_generic, have.result_generic, between)
end

-- The protocol and source pairs being checked by `satisfies`, keyed by type
-- name because substitution builds fresh objects for the same specialization.
local assuming = {}

-- Whether `source` provides every method of protocol `target` compatibly. A
-- pair already being checked is assumed to hold, so self-referential
-- protocols terminate.
local function satisfies(target, source)
  local pair = target.name .. " <- " .. source.name
  if assuming[pair] then
    return true
  end
  assuming[pair] = true
  local ok = true
  for _, method in ipairs(target.protocol.methods) do
    ok = ok and compatible(M.method(target, method.name), M.method(source, method.name), source.kind == "protocol")
  end
  assuming[pair] = nil
  return ok
end

local function is_exception(t)
  return t.kind == "record" and t.record.exception
end

function M.assignable(target, source)
  target, source = M.expand(target), M.expand(source)
  if source.kind == "union" then
    for _, m in ipairs(source.members) do
      if not M.assignable(target, m) then
        return false
      end
    end
    return true
  end
  if target.kind == "union" then
    for _, m in ipairs(target.members) do
      if M.assignable(m, source) then
        return true
      end
    end
    return false
  end
  if target.kind == "callable" then
    return M.same(target, source) or serves(target, source)
  end
  if target.kind == "tuple" and source.kind == "tuple" and #target.elements == #source.elements then
    for i, element in ipairs(target.elements) do
      if not M.assignable(element, source.elements[i]) then
        return false
      end
    end
    return true
  end
  return M.same(target, source)
    or is_exception(target) and target.record.type_name == "Exception" and is_exception(source)
    or target.kind == "protocol" and (source.kind == "record" or source.kind == "protocol" or M.iteration_item(source) ~= nil)
      and satisfies(target, source)
    -- A bounded type parameter serves wherever its bound does.
    or source.kind == "typevar" and source.bound ~= nil and M.assignable(target, source.bound)
end

-- The union of the members of `t` that `keep` accepts, or `t` itself when it
-- keeps them all.
function M.subset(t, keep)
  local kept = {}
  for _, m in ipairs(M.members(t)) do
    if keep(m) then
      kept[#kept + 1] = m
    end
  end
  if #kept == #M.members(t) then
    return t
  end
  return M.union(kept)
end

-- Whether protocol type `p` can hold a value of `t`, a list, dict, or tuple of
-- any item types, because `p` asks only for a parameterless `iter` method.
local function holds_any(p, t)
  if p.kind ~= "protocol" or not (t.kind == "list" or t.kind == "dict" or t.kind == "tuple") then
    return false
  end
  for _, method in ipairs(p.protocol.methods) do
    if method.name ~= "iter" or #M.method(p, "iter").params > 0 then
      return false
    end
  end
  return true
end

-- The message for adding member `m` to a union with `members`, or nil. Lists,
-- dicts, tuples, and callables are counted first, so their component types are
-- never compared.
function M.conflict(members, m)
  for _, other in ipairs(members) do
    if other.kind == m.kind and (m.kind == "list" or m.kind == "dict" or m.kind == "tuple" or m.kind == "callable") then
      return "a union can have only one " .. m.kind .. " member"
    elseif M.generic_decl(m) and M.generic_decl(other) == M.generic_decl(m) then
      return "a union can have only one specialization of " .. M.generic_decl(m).type_name
    end
    if M.assignable(other, m) or M.assignable(m, other) or holds_any(other, m) or holds_any(m, other) then
      return "union members " .. other.name .. " and " .. m.name .. " overlap"
    end
  end
end

-- The type `for` gives the items of tuple `t`: the union of its position types
-- without duplicate or subsumed members, or None when it has no positions.
-- Returns nil and the reason when that union is not a valid type.
function M.items(t)
  local kept = {}
  for _, element in ipairs(t.elements) do
    for _, m in ipairs(M.members(element)) do
      local subsumed = false
      for _, other in ipairs(kept) do
        subsumed = subsumed or M.assignable(other, m)
      end
      if not subsumed then
        local rest = {}
        for _, other in ipairs(kept) do
          if not M.assignable(m, other) then
            rest[#rest + 1] = other
          end
        end
        rest[#rest + 1] = m
        kept = rest
      end
    end
  end
  if #kept == 0 then
    return M.None
  end
  for i = 2, #kept do
    local message = M.conflict({ unpack(kept, 1, i - 1) }, kept[i])
    if message then
      return nil, message
    end
  end
  return M.union(kept)
end

-- The error for type argument `arg` of type parameter `typevar` that does not
-- satisfy its bound, or nil.
function M.unsatisfied(typevar, arg)
  -- A value of a type parameter reaches its bound's methods unconverted.
  if typevar.bound and (not M.assignable(typevar.bound, arg) or M.converts(arg, typevar.bound)) then
    return "type argument " .. arg.name .. " does not satisfy the bound " .. typevar.bound.name
      .. " of '" .. typevar.name .. "'"
  end
end

-- Whether `t` mentions a type parameter, or one in the set `only` when given.
-- `seen` stops at recursive aliases, which mention none.
local function has_typevar(t, seen, only)
  t = M.expand(t)
  if seen[t] then
    return false
  end
  seen[t] = true
  if t.kind == "typevar" then
    return not only or only[t] ~= nil
  end
  for _, part in ipairs(t.members or t.elements or t.params or t.args or {}) do
    if has_typevar(part, seen, only) then
      return true
    end
  end
  local inner = t.element or t.value or t.result
  return inner ~= nil and has_typevar(inner, seen, only)
end

-- Whether `t` mentions a type parameter that is a key of `set`.
function M.mentions(t, set)
  return has_typevar(t, {}, set)
end

-- `t` with each type parameter that `map` names replaced by its type
-- argument. Unions flatten and drop members they already hold.
function M.substitute(t, map)
  t = M.expand(t)
  local kind = t.kind
  if not has_typevar(t, {}) then
    return t
  elseif kind == "typevar" then
    return map[t] or t
  elseif kind == "list" then
    return M.list(M.substitute(t.element, map))
  elseif kind == "dict" then
    return M.dict(t.key, M.substitute(t.value, map))
  elseif kind == "tuple" then
    local elements = {}
    for i, element in ipairs(t.elements) do
      elements[i] = M.substitute(element, map)
    end
    return M.tuple(elements)
  elseif kind == "callable" then
    local params = {}
    for i, param in ipairs(t.params) do
      params[i] = M.substitute(param, map)
    end
    return M.callable(params, M.substitute(t.result, map))
  elseif kind == "record" then
    local args = {}
    for i, arg in ipairs(t.args) do
      args[i] = M.substitute(arg, map)
    end
    return M.generic(t.record, args)
  elseif kind == "protocol" then
    local args = {}
    for i, arg in ipairs(t.args) do
      args[i] = M.substitute(arg, map)
    end
    return M.protocol(t.protocol, args)
  elseif kind == "union" then
    local members = {}
    for _, member in ipairs(t.members) do
      for _, m in ipairs(M.members(M.substitute(member, map))) do
        local held = false
        for _, other in ipairs(members) do
          held = held or M.same(other, m)
        end
        if not held then
          members[#members + 1] = m
        end
      end
    end
    return M.union(members)
  end
  return t
end

return M
