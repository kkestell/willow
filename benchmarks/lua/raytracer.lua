local sqrt, huge = math.sqrt, math.huge
local DELTA = sqrt(2 ^ -52)
local function vec(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
local function scale(s, v) return vec(s * v.x, s * v.y, s * v.z) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function unitise(v) return scale(1 / sqrt(dot(v, v)), v) end
local function ray_sphere(sphere, origin, direction)
  local v = sub(sphere.center, origin)
  local b = dot(v, direction)
  local disc = b * b - dot(v, v) + sphere.radius * sphere.radius
  if disc < 0 then return huge end
  local d = sqrt(disc)
  local t2 = b + d
  if t2 < 0 then return huge end
  local t1 = b - d
  if t1 > 0 then return t1 end
  return t2
end
-- A scene is a sphere { center, radius } or a group { bound, children }.
local function intersect(scene, origin, direction, hit)
  if scene.children == nil then
    local distance = ray_sphere(scene, origin, direction)
    if distance >= hit.distance then return end
    hit.distance = distance
    hit.normal = unitise(sub(add(origin, scale(distance, direction)), scene.center))
    return
  end
  if ray_sphere(scene.bound, origin, direction) >= hit.distance then return end
  for _, child in ipairs(scene.children) do intersect(child, origin, direction, hit) end
end
local function shadowed(scene, origin, direction)
  if scene.children == nil then return ray_sphere(scene, origin, direction) < huge end
  if not (ray_sphere(scene.bound, origin, direction) < huge) then return false end
  for _, child in ipairs(scene.children) do
    if shadowed(child, origin, direction) then return true end
  end
  return false
end
local function ray_trace(light, origin, direction, scene)
  local hit = { distance = huge, normal = vec(0, 0, 0) }
  intersect(scene, origin, direction, hit)
  if hit.distance == huge then return 0 end
  local g = dot(hit.normal, light)
  if g >= 0 then return 0 end
  local point = add(add(origin, scale(hit.distance, direction)), scale(DELTA, hit.normal))
  if shadowed(scene, point, scale(-1, light)) then return 0 end
  return -g
end
local function create(level, center, radius)
  local sphere = { center = center, radius = radius }
  if level == 1 then return sphere end
  local children = { sphere }
  local offset = 3 * radius / sqrt(12)
  for _, dz in ipairs({ -1, 1 }) do
    for _, dx in ipairs({ -1, 1 }) do
      children[#children + 1] = create(level - 1, add(center, scale(offset, vec(dx, 1, dz))), 0.5 * radius)
    end
  end
  return { bound = { center = center, radius = 3 * radius }, children = children }
end
local n = tonumber(arg[1])
local samples = 4
local light = unitise(vec(-1, -3, 2))
local scene = create(6, vec(0, -1, 0), 1)
local eye = vec(0, 0, -4)
io.write(string.format("P5\n%d %d\n255\n", n, n))
for y = n - 1, 0, -1 do
  local row = {}
  for x = 0, n - 1 do
    local g = 0
    for dx = 0, samples - 1 do
      for dy = 0, samples - 1 do
        local direction = unitise(vec(x + dx / samples - n / 2, y + dy / samples - n / 2, n))
        g = g + ray_trace(light, eye, direction, scene)
      end
    end
    row[x + 1] = string.char(math.floor(0.5 + 255 * g / (samples * samples)))
  end
  io.write(table.concat(row))
end
