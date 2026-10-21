import math, sys
PI = math.pi
SOLAR_MASS = 4 * PI * PI
DPY = 365.24
class Body:
    __slots__ = ("x", "y", "z", "vx", "vy", "vz", "mass")
    def __init__(self, x, y, z, vx, vy, vz, mass):
        self.x, self.y, self.z, self.vx, self.vy, self.vz, self.mass = x, y, z, vx, vy, vz, mass
def planet(x, y, z, vx, vy, vz, m):
    return Body(x, y, z, vx * DPY, vy * DPY, vz * DPY, m * SOLAR_MASS)
bodies = [
    Body(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, SOLAR_MASS),
    planet(4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01, 1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05, 9.54791938424326609e-04),
    planet(8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01, -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05, 2.85885980666130812e-04),
    planet(1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01, 2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05, 4.36624404335156298e-05),
    planet(1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01, 2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05, 5.15138902046611451e-05),
]
def energy(bs):
    e = 0.0
    for i, a in enumerate(bs):
        e += 0.5 * a.mass * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz)
        for b in bs[i + 1:]:
            dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
            e -= a.mass * b.mass / math.sqrt(dx * dx + dy * dy + dz * dz)
    return e
def advance(bs, dt):
    count = len(bs)
    for i in range(count):
        a = bs[i]
        for j in range(i + 1, count):
            b = bs[j]
            dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
            d2 = dx * dx + dy * dy + dz * dz
            mag = dt / (d2 * math.sqrt(d2))
            am, bm = a.mass * mag, b.mass * mag
            a.vx -= dx * bm; a.vy -= dy * bm; a.vz -= dz * bm
            b.vx += dx * am; b.vy += dy * am; b.vz += dz * am
    for b in bs:
        b.x += dt * b.vx; b.y += dt * b.vy; b.z += dt * b.vz
n = int(sys.argv[1])
px = py = pz = 0.0
for b in bodies:
    px += b.vx * b.mass; py += b.vy * b.mass; pz += b.vz * b.mass
bodies[0].vx, bodies[0].vy, bodies[0].vz = -px / SOLAR_MASS, -py / SOLAR_MASS, -pz / SOLAR_MASS
print(f"{energy(bodies):.9f}")
for _ in range(n):
    advance(bodies, 0.01)
print(f"{energy(bodies):.9f}")
