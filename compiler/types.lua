-- Type objects. Every type has a `kind` and a display `name`. Scalars and
-- records are single objects compared by identity.
local M = {}

for name in ("int float bool str None"):gmatch("%S+") do
  M[name] = { kind = name, name = name }
end

local SCALARS = { int = true, float = true, bool = true, str = true, None = true }

function M.list(element)
  return { kind = "list", element = element, name = "list[" .. element.name .. "]" }
end

function M.dict(key, value)
  return { kind = "dict", key = key, value = value, name = "dict[" .. key.name .. ", " .. value.name .. "]" }
end

function M.record(decl)
  return { kind = "record", record = decl, name = decl.type_name }
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
    if not SCALARS[m.kind] then
      return false
    end
  end
  return true
end

-- In a type with both int and float members, floats are boxed at run time so
-- that they differ from ints.
function M.boxed(t)
  return M.has(t, "int") and M.has(t, "float")
end

-- Union members are matched by kind, or by record for records.
local function key(t)
  return t.kind == "record" and t.record or t.kind
end

-- `assumed` holds pairs already being compared, so recursive types terminate.
local function same(a, b, assumed)
  a, b = M.expand(a), M.expand(b)
  if a == b then
    return true
  end
  if a.kind ~= b.kind or a.kind == "record" or SCALARS[a.kind] then
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

-- The message for adding member `m` to a union with `members`, or nil. Lists
-- and dicts are counted first, so element types are never compared.
function M.conflict(members, m)
  for _, other in ipairs(members) do
    if other.kind == m.kind and (m.kind == "list" or m.kind == "dict") then
      return "a union can have only one " .. m.kind .. " member"
    end
    if M.assignable(other, m) or M.assignable(m, other) then
      return "union members " .. other.name .. " and " .. m.name .. " overlap"
    end
  end
end

return M
