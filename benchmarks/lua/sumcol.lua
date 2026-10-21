local total = 0
for line in io.lines() do total = total + tonumber(line) end
io.write(string.format("%d\n", total))
