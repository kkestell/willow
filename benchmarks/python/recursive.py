import sys
sys.setrecursionlimit(100000)
def ack(m, n):
    if m == 0:
        return n + 1
    if n == 0:
        return ack(m - 1, 1)
    return ack(m - 1, ack(m, n - 1))
def fib(n):
    return 1 if n < 2 else fib(n - 2) + fib(n - 1)
def fib_float(n):
    return 1.0 if n < 2.0 else fib_float(n - 2.0) + fib_float(n - 1.0)
def tak(x, y, z):
    return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y)) if y < x else z
def tak_float(x, y, z):
    return tak_float(tak_float(x - 1.0, y, z), tak_float(y - 1.0, z, x), tak_float(z - 1.0, x, y)) if y < x else z
n = int(sys.argv[1])
print(f"Ack(3,{n + 1}): {ack(3, n + 1)}")
print(f"Fib({27.0 + n:.1f}): {fib_float(27.0 + n):.1f}")
print(f"Tak({3 * n},{2 * n},{n}): {tak(3 * n, 2 * n, n)}")
print(f"Fib(3): {fib(3)}")
print(f"Tak(3.0,2.0,1.0): {tak_float(3.0, 2.0, 1.0):.1f}")
