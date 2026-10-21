import sys
def make_matrix(rows, columns):
    return [[i * columns + j + 1 for j in range(columns)] for i in range(rows)]
def multiply(rows, columns, a, b):
    product = []
    for i in range(rows):
        a_row = a[i]
        row = []
        for j in range(columns):
            total = 0
            for k in range(columns):
                total += a_row[k] * b[k][j]
            row.append(total)
        product.append(row)
    return product
n = int(sys.argv[1])
size = 30
a = make_matrix(size, size)
b = make_matrix(size, size)
for _ in range(n):
    product = multiply(size, size, a, b)
print(product[0][0], product[2][3], product[3][2], product[4][4])
