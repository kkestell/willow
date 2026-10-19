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

-- `typing.Callable[[A, B], R]`: a function taking exactly those positional
-- arguments. It is compared by structure.
function M.callable(params, result)
  local names = {}
  for i, param in ipairs(params) do
    names[i] = param.name
  end
  return {
    kind = "callable", params = params, result = result,
    name = "typing.Callable[[" .. table.concat(names, ", ") .. "], " .. result.name .. "]",
  }
end

-- The type of a declared function as a value. It is compared by identity, so
-- calls through it use the declaration's own parameters.
-- A `bound` method keeps its receiver, so calls skip its `self` parameter.
function M.func(decl, bound)
  local name = bound and decl.class.type_name .. "." .. decl.name or decl.type_name
  return { kind = "function", fn = decl, bound = bound, name = "function " .. name }
end

-- The parameters a call through function type `t` binds.
function M.params(t)
  return t.bound and { unpack(t.fn.params, 2) } or t.fn.params
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
      names[#names + 1] = m.name
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
  return t.record or t.enum or t.fn or (t.kind == "typevar" and t) or t.kind
end

-- `assumed` holds pairs already being compared, so recursive types terminate.
local function same(a, b, assumed)
  a, b = M.expand(a), M.expand(b)
  if a == b then
    return true
  end
  if a.kind ~= b.kind or a.kind == "record" or a.kind == "function" or a.kind == "typevar" or SCALARS[a.kind] then
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
  elseif a.kind == "tuple" or a.kind == "callable" then
    local x, y = a.elements or a.params, b.elements or b.params
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
    params, result = {}, source.fn.return_type
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

-- The message for adding member `m` to a union with `members`, or nil. Lists,
-- dicts, tuples, and callables are counted first, so their component types are
-- never compared.
function M.conflict(members, m)
  for _, other in ipairs(members) do
    if other.kind == m.kind and (m.kind == "list" or m.kind == "dict" or m.kind == "tuple" or m.kind == "callable") then
      return "a union can have only one " .. m.kind .. " member"
    end
    if M.assignable(other, m) or M.assignable(m, other) then
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
  for _, part in ipairs(t.members or t.elements or t.params or {}) do
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
