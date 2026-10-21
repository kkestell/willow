import sys
TABLE = str.maketrans("ACBDGHKMNSRUTWVYacbdghkmnsrutwvy", "TGVHCDMKNSYAAWBRTGVHCDMKNSYAAWBR")
def write_reversed(lines):
    sequence = "".join(lines).translate(TABLE)[::-1]
    for i in range(0, len(sequence), 60):
        sys.stdout.write(sequence[i:i + 60] + "\n")
lines = []
for line in sys.stdin:
    if line.startswith(">"):
        write_reversed(lines)
        lines = []
        sys.stdout.write(line)
    else:
        lines.append(line.rstrip("\n"))
write_reversed(lines)
