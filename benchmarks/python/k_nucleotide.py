import sys
SYMBOLS = "ACGT"
PROBABILITIES = [0.3029549426680, 0.1979883004921, 0.1975473066391, 0.3015094502008]
def generate(n):
    cumulative, total = [], 0.0
    for p in PROBABILITIES:
        total += p
        cumulative.append(total)
    chars, last = [], 42
    for _ in range(n):
        last = (last * 3877 + 29573) % 139968
        r = last / 139968
        choice = 3
        for i in range(4):
            if r < cumulative[i]:
                choice = i
                break
        chars.append(SYMBOLS[choice])
    return "".join(chars)
def count(sequence, k):
    counts = {}
    for i in range(len(sequence) - k + 1):
        kmer = sequence[i:i + k]
        counts[kmer] = counts.get(kmer, 0) + 1
    return counts
def print_frequencies(sequence, k):
    counts = count(sequence, k)
    total = len(sequence) - k + 1
    for kmer in sorted(counts, key=lambda kmer: (-counts[kmer], kmer)):
        print(f"{kmer} {100 * counts[kmer] / total:.3f}")
    print()
def print_count(sequence, kmer):
    print(f"{count(sequence, len(kmer)).get(kmer, 0)}\t{kmer}")
sequence = generate(int(sys.argv[1]))
print_frequencies(sequence, 1)
print_frequencies(sequence, 2)
for kmer in ["GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"]:
    print_count(sequence, kmer)
