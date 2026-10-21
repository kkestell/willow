package main

import (
	"bufio"
	"os"
	"strconv"
)

const alu = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG" + "GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA" +
	"CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT" + "ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA" +
	"GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG" + "AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC" +
	"AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"

type entry struct {
	symbol      byte
	probability float64
}

var iub = []entry{
	{'a', 0.27}, {'c', 0.12}, {'g', 0.12}, {'t', 0.27}, {'B', 0.02}, {'D', 0.02}, {'H', 0.02}, {'K', 0.02},
	{'M', 0.02}, {'N', 0.02}, {'R', 0.02}, {'S', 0.02}, {'V', 0.02}, {'W', 0.02}, {'Y', 0.02},
}
var homoSapiens = []entry{{'a', 0.3029549426680}, {'c', 0.1979883004921}, {'g', 0.1975473066391}, {'t', 0.3015094502008}}
var last = 42
var out = bufio.NewWriter(os.Stdout)

func random() float64 {
	last = (last*3877 + 29573) % 139968
	return float64(last) / 139968
}

func cumulative(table []entry) []entry {
	result, total := make([]entry, len(table)), 0.0
	for i, e := range table {
		total += e.probability
		result[i] = entry{e.symbol, total}
	}
	return result
}

func repeatFasta(header, sequence string, count int) {
	out.WriteString(header + "\n")
	doubled, length, position := sequence+sequence, len(sequence), 0
	for count > 0 {
		width := min(count, 60)
		out.WriteString(doubled[position : position+width])
		out.WriteByte('\n')
		position = (position + width) % length
		count -= width
	}
}

func randomFasta(header string, table []entry, count int) {
	out.WriteString(header + "\n")
	line := make([]byte, 61)
	for count > 0 {
		width := min(count, 60)
		for i := 0; i < width; i++ {
			r := random()
			choice := table[len(table)-1].symbol
			for _, e := range table {
				if r < e.probability {
					choice = e.symbol
					break
				}
			}
			line[i] = choice
		}
		line[width] = '\n'
		out.Write(line[:width+1])
		count -= width
	}
}

func main() {
	n, _ := strconv.Atoi(os.Args[1])
	repeatFasta(">ONE Homo sapiens alu", alu, 2*n)
	randomFasta(">TWO IUB ambiguity codes", cumulative(iub), 3*n)
	randomFasta(">THREE Homo sapiens frequency", cumulative(homoSapiens), 5*n)
	out.Flush()
}
