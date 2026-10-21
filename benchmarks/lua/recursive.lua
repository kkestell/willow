local function ack(m, n)
  if m == 0 then return n + 1 end
  if n == 0 then return ack(m - 1, 1) end
  return ack(m - 1, ack(m, n - 1))
end
local function fib(n)
  if n < 2 then return 1 end
  return fib(n - 2) + fib(n - 1)
end
local function tak(x, y, z)
  if y < x then return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y)) end
  return z
end
local n = tonumber(arg[1])
io.write(string.format("Ack(3,%d): %d\n", n + 1, ack(3, n + 1)))
io.write(string.format("Fib(%.1f): %.1f\n", 27.0 + n, fib(27.0 + n)))
io.write(string.format("Tak(%d,%d,%d): %d\n", 3 * n, 2 * n, n, tak(3 * n, 2 * n, n)))
io.write(string.format("Fib(3): %d\n", fib(3)))
io.write(string.format("Tak(3.0,2.0,1.0): %.1f\n", tak(3.0, 2.0, 1.0)))
