import sys
def main(n):
    perm1, perm, count = list(range(n)), [0] * n, [0] * n
    max_flips = checksum = permutations = 0
    r = n
    while True:
        while r != 1:
            count[r - 1] = r
            r -= 1
        perm[:] = perm1
        flips = 0
        k = perm[0]
        while k != 0:
            lo, hi = 0, k
            while lo < hi:
                perm[lo], perm[hi] = perm[hi], perm[lo]
                lo += 1
                hi -= 1
            flips += 1
            k = perm[0]
        if flips > max_flips:
            max_flips = flips
        checksum += flips if permutations % 2 == 0 else -flips
        while True:
            if r == n:
                print(checksum)
                print(f"Pfannkuchen({n}) = {max_flips}")
                return
            first = perm1[0]
            for i in range(r):
                perm1[i] = perm1[i + 1]
            perm1[r] = first
            count[r] -= 1
            if count[r] > 0:
                break
            r += 1
        permutations += 1
main(int(sys.argv[1]))
