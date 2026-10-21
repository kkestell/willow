local function make_matrix(rows, columns)
  local matrix, count = {}, 1
  for i = 1, rows do
    local row = {}
    for j = 1, columns do row[j] = count; count = count + 1 end
    matrix[i] = row
  end
  return matrix
end
local function multiply(rows, columns, a, b)
  local product = {}
  for i = 1, rows do
    local a_row, row = a[i], {}
    for j = 1, columns do
      local total = 0
      for k = 1, columns do total = total + a_row[k] * b[k][j] end
      row[j] = total
    end
    product[i] = row
  end
  return product
end
local n = tonumber(arg[1])
local size = 30
local a, b = make_matrix(size, size), make_matrix(size, size)
local product
for _ = 1, n do product = multiply(size, size, a, b) end
io.write(product[1][1], " ", product[3][4], " ", product[4][3], " ", product[5][5], "\n")
