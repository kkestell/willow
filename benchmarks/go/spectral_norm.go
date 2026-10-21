package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
)

func a(i, j int) float64 { return 1.0 / float64((i+j)*(i+j+1)/2+i+1) }

func times(v, out []float64) {
	for i := range out {
		t := 0.0
		for j := range v {
			t += a(i, j) * v[j]
		}
		out[i] = t
	}
}

func timesT(v, out []float64) {
	for i := range out {
		t := 0.0
		for j := range v {
			t += a(j, i) * v[j]
		}
		out[i] = t
	}
}

func main() {
	n, _ := strconv.Atoi(os.Args[1])
	u, v, s := make([]float64, n), make([]float64, n), make([]float64, n)
	for i := range u {
		u[i] = 1
	}
	for i := 0; i < 10; i++ {
		times(u, s)
		timesT(s, v)
		times(v, s)
		timesT(s, u)
	}
	var vbv, vv float64
	for i := range u {
		vbv += u[i] * v[i]
		vv += v[i] * v[i]
	}
	fmt.Printf("%.9f\n", math.Sqrt(vbv/vv))
}
