package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
)

const solarMass = 4 * math.Pi * math.Pi
const dpy = 365.24

type Body struct{ x, y, z, vx, vy, vz, mass float64 }

func planet(x, y, z, vx, vy, vz, m float64) *Body {
	return &Body{x, y, z, vx * dpy, vy * dpy, vz * dpy, m * solarMass}
}

func energy(bs []*Body) float64 {
	e := 0.0
	for i, a := range bs {
		e += 0.5 * a.mass * (a.vx*a.vx + a.vy*a.vy + a.vz*a.vz)
		for _, b := range bs[i+1:] {
			dx, dy, dz := a.x-b.x, a.y-b.y, a.z-b.z
			e -= a.mass * b.mass / math.Sqrt(dx*dx+dy*dy+dz*dz)
		}
	}
	return e
}

func advance(bs []*Body, dt float64) {
	for i, a := range bs {
		for _, b := range bs[i+1:] {
			dx, dy, dz := a.x-b.x, a.y-b.y, a.z-b.z
			d2 := dx*dx + dy*dy + dz*dz
			mag := dt / (d2 * math.Sqrt(d2))
			am, bm := a.mass*mag, b.mass*mag
			a.vx -= dx * bm
			a.vy -= dy * bm
			a.vz -= dz * bm
			b.vx += dx * am
			b.vy += dy * am
			b.vz += dz * am
		}
	}
	for _, b := range bs {
		b.x += dt * b.vx
		b.y += dt * b.vy
		b.z += dt * b.vz
	}
}

func main() {
	n, _ := strconv.Atoi(os.Args[1])
	bs := []*Body{
		{0, 0, 0, 0, 0, 0, solarMass},
		planet(4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01, 1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05, 9.54791938424326609e-04),
		planet(8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01, -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05, 2.85885980666130812e-04),
		planet(1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01, 2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05, 4.36624404335156298e-05),
		planet(1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01, 2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05, 5.15138902046611451e-05),
	}
	var px, py, pz float64
	for _, b := range bs {
		px += b.vx * b.mass
		py += b.vy * b.mass
		pz += b.vz * b.mass
	}
	bs[0].vx, bs[0].vy, bs[0].vz = -px/solarMass, -py/solarMass, -pz/solarMass
	fmt.Printf("%.9f\n", energy(bs))
	for i := 0; i < n; i++ {
		advance(bs, 0.01)
	}
	fmt.Printf("%.9f\n", energy(bs))
}
