local n = tonumber(arg[1])
local checksum = 0
for y = 0, n - 1 do
  local ci = 2 * y / n - 1
  local byte, bits = 0, 0
  for x = 0, n - 1 do
    local cr = 2 * x / n - 1.5
    local zr, zi, zr2, zi2, i = 0, 0, 0, 0, 0
    while i < 50 and zr2 + zi2 <= 4 do
      zi = 2 * zr * zi + ci
      zr = zr2 - zi2 + cr
      zr2 = zr * zr
      zi2 = zi * zi
      i = i + 1
    end
    byte = byte * 2
    if zr2 + zi2 <= 4 then byte = byte + 1 end
    bits = bits + 1
    if bits == 8 then
      checksum = (checksum * 31 + byte) % 1000000007
      byte, bits = 0, 0
    end
  end
  if bits ~= 0 then
    while bits < 8 do byte = byte * 2; bits = bits + 1 end
    checksum = (checksum * 31 + byte) % 1000000007
  end
end
io.write(checksum, "\n")
