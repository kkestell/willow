import sys
n = int(sys.argv[1])
first = {f"foo_{i}": i for i in range(10000)}
second = {}
for _ in range(n):
    for key in first:
        second[key] = second.get(key, 0) + first[key]
print(first["foo_1"], first["foo_9999"], second["foo_1"], second["foo_9999"])
