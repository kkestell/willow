import sys
class Node:
    __slots__ = ("left", "right")
    def __init__(self, left, right):
        self.left, self.right = left, right
def make(d):
    return Node(None, None) if d == 0 else Node(make(d - 1), make(d - 1))
def check(n):
    return 1 if n.left is None else 1 + check(n.left) + check(n.right)
n = int(sys.argv[1])
min_depth = 4
max_depth = max(min_depth + 2, n)
print(f"stretch tree of depth {max_depth + 1}\t check: {check(make(max_depth + 1))}")
long_lived = make(max_depth)
for d in range(min_depth, max_depth + 1, 2):
    iterations = 1 << (max_depth - d + min_depth)
    total = 0
    for _ in range(iterations):
        total += check(make(d))
    print(f"{iterations}\t trees of depth {d}\t check: {total}")
print(f"long lived tree of depth {max_depth}\t check: {check(long_lived)}")
