import math
import sys
INFINITY = math.inf
DELTA = math.sqrt(sys.float_info.epsilon)
class Vec:
    __slots__ = ("x", "y", "z")
    def __init__(self, x, y, z):
        self.x, self.y, self.z = x, y, z
class Sphere:
    __slots__ = ("center", "radius")
    def __init__(self, center, radius):
        self.center, self.radius = center, radius
class Group:
    __slots__ = ("bound", "children")
    def __init__(self, bound, children):
        self.bound, self.children = bound, children
class Hit:
    __slots__ = ("distance", "normal")
    def __init__(self, distance, normal):
        self.distance, self.normal = distance, normal
def add(a, b):
    return Vec(a.x + b.x, a.y + b.y, a.z + b.z)
def sub(a, b):
    return Vec(a.x - b.x, a.y - b.y, a.z - b.z)
def scale(s, v):
    return Vec(s * v.x, s * v.y, s * v.z)
def dot(a, b):
    return a.x * b.x + a.y * b.y + a.z * b.z
def unitise(v):
    return scale(1.0 / math.sqrt(dot(v, v)), v)
def ray_sphere(sphere, origin, direction):
    v = sub(sphere.center, origin)
    b = dot(v, direction)
    disc = b * b - dot(v, v) + sphere.radius * sphere.radius
    if disc < 0.0:
        return INFINITY
    d = math.sqrt(disc)
    t2 = b + d
    if t2 < 0.0:
        return INFINITY
    t1 = b - d
    return t1 if t1 > 0.0 else t2
def intersect(scene, origin, direction, hit):
    if isinstance(scene, Sphere):
        distance = ray_sphere(scene, origin, direction)
        if distance >= hit.distance:
            return
        hit.distance = distance
        hit.normal = unitise(sub(add(origin, scale(distance, direction)), scene.center))
        return
    if ray_sphere(scene.bound, origin, direction) >= hit.distance:
        return
    for child in scene.children:
        intersect(child, origin, direction, hit)
def shadowed(scene, origin, direction):
    if isinstance(scene, Sphere):
        return ray_sphere(scene, origin, direction) < INFINITY
    if not ray_sphere(scene.bound, origin, direction) < INFINITY:
        return False
    for child in scene.children:
        if shadowed(child, origin, direction):
            return True
    return False
def ray_trace(light, origin, direction, scene):
    hit = Hit(INFINITY, Vec(0.0, 0.0, 0.0))
    intersect(scene, origin, direction, hit)
    if hit.distance == INFINITY:
        return 0.0
    g = dot(hit.normal, light)
    if g >= 0.0:
        return 0.0
    point = add(add(origin, scale(hit.distance, direction)), scale(DELTA, hit.normal))
    return 0.0 if shadowed(scene, point, scale(-1.0, light)) else -g
def create(level, center, radius):
    sphere = Sphere(center, radius)
    if level == 1:
        return sphere
    children = [sphere]
    offset = 3.0 * radius / math.sqrt(12.0)
    for dz in (-1.0, 1.0):
        for dx in (-1.0, 1.0):
            children.append(create(level - 1, add(center, scale(offset, Vec(dx, 1.0, dz))), 0.5 * radius))
    return Group(Sphere(center, 3.0 * radius), children)
n = int(sys.argv[1])
samples = 4
light = unitise(Vec(-1.0, -3.0, 2.0))
scene = create(6, Vec(0.0, -1.0, 0.0), 1.0)
eye = Vec(0.0, 0.0, -4.0)
out = sys.stdout.buffer
out.write(f"P5\n{n} {n}\n255\n".encode())
for y in range(n - 1, -1, -1):
    row = bytearray()
    for x in range(n):
        g = 0.0
        for dx in range(samples):
            for dy in range(samples):
                direction = unitise(Vec(x + dx / samples - n / 2.0, y + dy / samples - n / 2.0, float(n)))
                g += ray_trace(light, eye, direction, scene)
        row.append(int(0.5 + 255.0 * g / (samples * samples)))
    out.write(row)
