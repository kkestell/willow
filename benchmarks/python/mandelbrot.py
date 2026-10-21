import sys
def main(n):
    checksum = 0
    for y in range(n):
        ci = 2.0 * y / n - 1.0
        byte = bits = 0
        for x in range(n):
            cr = 2.0 * x / n - 1.5
            zr = zi = zr2 = zi2 = 0.0
            i = 0
            while i < 50 and zr2 + zi2 <= 4.0:
                zi = 2.0 * zr * zi + ci
                zr = zr2 - zi2 + cr
                zr2 = zr * zr
                zi2 = zi * zi
                i += 1
            byte *= 2
            if zr2 + zi2 <= 4.0:
                byte += 1
            bits += 1
            if bits == 8:
                checksum = (checksum * 31 + byte) % 1000000007
                byte = bits = 0
        if bits != 0:
            while bits < 8:
                byte *= 2
                bits += 1
            checksum = (checksum * 31 + byte) % 1000000007
    print(checksum)
main(int(sys.argv[1]))
