class Node { constructor(left, right) { this.left = left; this.right = right; } }
const make = (d) => d === 0 ? new Node(null, null) : new Node(make(d - 1), make(d - 1));
const check = (n) => n.left === null ? 1 : 1 + check(n.left) + check(n.right);
const n = +process.argv[2], minDepth = 4, maxDepth = Math.max(minDepth + 2, n);
console.log(`stretch tree of depth ${maxDepth + 1}\t check: ${check(make(maxDepth + 1))}`);
const longLived = make(maxDepth);
for (let d = minDepth; d <= maxDepth; d += 2) {
  const iterations = 1 << (maxDepth - d + minDepth);
  let total = 0;
  for (let i = 0; i < iterations; i++) total += check(make(d));
  console.log(`${iterations}\t trees of depth ${d}\t check: ${total}`);
}
console.log(`long lived tree of depth ${maxDepth}\t check: ${check(longLived)}`);
