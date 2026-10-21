import sys
last = 42
def random(maximum):
    global last
    last = (last * 3877 + 29573) % 139968
    return maximum * last / 139968
def heapsort(n, items):
    ir = n
    l = n // 2 + 1
    while True:
        if l > 1:
            l -= 1
            rra = items[l]
        else:
            rra = items[ir]
            items[ir] = items[1]
            ir -= 1
            if ir == 1:
                items[1] = rra
                return
        i = l
        j = l * 2
        while j <= ir:
            if j < ir and items[j] < items[j + 1]:
                j += 1
            if rra < items[j]:
                items[i] = items[j]
                i = j
                j += i
            else:
                j = ir + 1
        items[i] = rra
n = int(sys.argv[1])
items = [0.0] + [random(1.0) for _ in range(n)]
heapsort(n, items)
print(f"{items[n]:.10f}")
