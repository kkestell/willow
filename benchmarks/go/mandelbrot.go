package main

import (
	"fmt"
	"os"
	"strconv"
)

func main() {
	n, _ := strconv.Atoi(os.Args[1])
	size := float64(n)
	checksum := 0
	for y := 0; y < n; y++ {
		ci := 2*float64(y)/size - 1
		byte, bits := 0, 0
		for x := 0; x < n; x++ {
			cr := 2*float64(x)/size - 1.5
			zr, zi, zr2, zi2, i := 0.0, 0.0, 0.0, 0.0, 0
			for i < 50 && zr2+zi2 <= 4 {
				zi = 2*zr*zi + ci
				zr = zr2 - zi2 + cr
				zr2 = zr * zr
				zi2 = zi * zi
				i++
			}
			byte *= 2
			if zr2+zi2 <= 4 {
				byte++
			}
			bits++
			if bits == 8 {
				checksum = (checksum*31 + byte) % 1000000007
				byte, bits = 0, 0
			}
		}
		if bits != 0 {
			for bits < 8 {
				byte *= 2
				bits++
			}
			checksum = (checksum*31 + byte) % 1000000007
		}
	}
	fmt.Println(checksum)
}
