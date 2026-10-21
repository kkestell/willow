import math, sys
def a(i, j):
    return 1.0 / ((i + j) * (i + j + 1) // 2 + i + 1)
def times(v, out):
    n = len(v)
    for i in range(n):
        t = 0.0
        for j in range(n):
            t += a(i, j) * v[j]
        out[i] = t
def times_t(v, out):
    n = len(v)
    for i in range(n):
        t = 0.0
        for j in range(n):
            t += a(j, i) * v[j]
        out[i] = t
n = int(sys.argv[1])
u, v, s = [1.0] * n, [0.0] * n, [0.0] * n
for _ in range(10):
    times(u, s); times_t(s, v); times(v, s); times_t(s, u)
vbv = sum(x * y for x, y in zip(u, v))
vv = sum(y * y for y in v)
print(f"{math.sqrt(vbv / vv):.9f}")
