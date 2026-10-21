import sys
ALU = ("GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG" "GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA"
       "CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT" "ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA"
       "GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG" "AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC"
       "AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA")
IUB = [("a", 0.27), ("c", 0.12), ("g", 0.12), ("t", 0.27), ("B", 0.02), ("D", 0.02), ("H", 0.02), ("K", 0.02),
       ("M", 0.02), ("N", 0.02), ("R", 0.02), ("S", 0.02), ("V", 0.02), ("W", 0.02), ("Y", 0.02)]
HOMO_SAPIENS = [("a", 0.3029549426680), ("c", 0.1979883004921), ("g", 0.1975473066391), ("t", 0.3015094502008)]
last = 42
def random():
    global last
    last = (last * 3877 + 29573) % 139968
    return last / 139968
def cumulative(table):
    result, total = [], 0.0
    for symbol, probability in table:
        total += probability
        result.append((symbol, total))
    return result
def repeat_fasta(header, sequence, count):
    out = sys.stdout.write
    out(header + "\n")
    doubled, length, position = sequence + sequence, len(sequence), 0
    while count > 0:
        width = min(count, 60)
        out(doubled[position:position + width] + "\n")
        position = (position + width) % length
        count -= width
def random_fasta(header, table, count):
    out = sys.stdout.write
    out(header + "\n")
    while count > 0:
        width = min(count, 60)
        line = []
        for _ in range(width):
            r = random()
            choice = table[-1][0]
            for symbol, probability in table:
                if r < probability:
                    choice = symbol
                    break
            line.append(choice)
        out("".join(line) + "\n")
        count -= width
n = int(sys.argv[1])
repeat_fasta(">ONE Homo sapiens alu", ALU, 2 * n)
random_fasta(">TWO IUB ambiguity codes", cumulative(IUB), 3 * n)
random_fasta(">THREE Homo sapiens frequency", cumulative(HOMO_SAPIENS), 5 * n)
