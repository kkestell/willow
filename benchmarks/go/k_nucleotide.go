package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
)

const symbols = "ACGT"

var probabilities = []float64{0.3029549426680, 0.1979883004921, 0.1975473066391, 0.3015094502008}
var out = bufio.NewWriter(os.Stdout)

func generate(n int) string {
	cumulative, total := make([]float64, 4), 0.0
	for i, p := range probabilities {
		total += p
		cumulative[i] = total
	}
	sequence, last := make([]byte, n), 42
	for i := range sequence {
		last = (last*3877 + 29573) % 139968
		r := float64(last) / 139968
		choice := 3
		for j := 0; j < 4; j++ {
			if r < cumulative[j] {
				choice = j
				break
			}
		}
		sequence[i] = symbols[choice]
	}
	return string(sequence)
}

func count(sequence string, k int) map[string]int {
	counts := make(map[string]int)
	for i := 0; i+k <= len(sequence); i++ {
		counts[sequence[i:i+k]]++
	}
	return counts
}

func printFrequencies(sequence string, k int) {
	counts := count(sequence, k)
	kmers := make([]string, 0, len(counts))
	for kmer := range counts {
		kmers = append(kmers, kmer)
	}
	sort.Slice(kmers, func(i, j int) bool {
		if counts[kmers[i]] != counts[kmers[j]] {
			return counts[kmers[i]] > counts[kmers[j]]
		}
		return kmers[i] < kmers[j]
	})
	total := float64(len(sequence) - k + 1)
	for _, kmer := range kmers {
		fmt.Fprintf(out, "%s %.3f\n", kmer, 100*float64(counts[kmer])/total)
	}
	fmt.Fprintln(out)
}

func printCount(sequence, kmer string) {
	fmt.Fprintf(out, "%d\t%s\n", count(sequence, len(kmer))[kmer], kmer)
}

func main() {
	n, _ := strconv.Atoi(os.Args[1])
	sequence := generate(n)
	printFrequencies(sequence, 1)
	printFrequencies(sequence, 2)
	for _, kmer := range []string{"GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"} {
		printCount(sequence, kmer)
	}
	out.Flush()
}
