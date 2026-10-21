import sys
def count_primes(limit):
    flags = [True] * limit
    count = 0
    for i in range(2, limit):
        if flags[i]:
            count += 1
            for j in range(i + i, limit, i):
                flags[j] = False
    return count
n = int(sys.argv[1])
for i in range(3):
    limit = 10000 << (n - i)
    print(f"Primes up to {limit:8d} {count_primes(limit):8d}")
