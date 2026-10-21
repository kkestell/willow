local last = 42
local function random(maximum)
  last = (last * 3877 + 29573) % 139968
  return maximum * last / 139968
end
local function heapsort(n, items)
  local ir, l = n, math.floor(n / 2) + 1
  while true do
    local rra
    if l > 1 then
      l = l - 1
      rra = items[l]
    else
      rra = items[ir]
      items[ir] = items[1]
      ir = ir - 1
      if ir == 1 then items[1] = rra; return end
    end
    local i, j = l, l * 2
    while j <= ir do
      if j < ir and items[j] < items[j + 1] then j = j + 1 end
      if rra < items[j] then
        items[i] = items[j]
        i = j
        j = j + i
      else
        j = ir + 1
      end
    end
    items[i] = rra
  end
end
local n = tonumber(arg[1])
local items = {}
for i = 1, n do items[i] = random(1) end
heapsort(n, items)
io.write(string.format("%.10f\n", items[n]))
