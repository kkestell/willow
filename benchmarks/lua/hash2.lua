local n = tonumber(arg[1])
local first, second = {}, {}
for i = 0, 9999 do first["foo_" .. i] = i end
for _ = 1, n do
  for key in pairs(first) do second[key] = (second[key] or 0) + first[key] end
end
io.write(first.foo_1, " ", first.foo_9999, " ", second.foo_1, " ", second.foo_9999, "\n")
