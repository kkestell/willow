package main

import (
	"fmt"
	"os"
	"strconv"
)

type Node struct{ left, right *Node }

func make_(d int) *Node {
	if d == 0 {
		return &Node{}
	}
	return &Node{make_(d - 1), make_(d - 1)}
}

func check(n *Node) int {
	if n.left == nil {
		return 1
	}
	return 1 + check(n.left) + check(n.right)
}

func main() {
	n, _ := strconv.Atoi(os.Args[1])
	minDepth, maxDepth := 4, n
	if maxDepth < minDepth+2 {
		maxDepth = minDepth + 2
	}
	fmt.Printf("stretch tree of depth %d\t check: %d\n", maxDepth+1, check(make_(maxDepth+1)))
	longLived := make_(maxDepth)
	for d := minDepth; d <= maxDepth; d += 2 {
		iterations, total := 1<<(maxDepth-d+minDepth), 0
		for i := 0; i < iterations; i++ {
			total += check(make_(d))
		}
		fmt.Printf("%d\t trees of depth %d\t check: %d\n", iterations, d, total)
	}
	fmt.Printf("long lived tree of depth %d\t check: %d\n", maxDepth, check(longLived))
}
