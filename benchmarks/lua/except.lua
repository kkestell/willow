local hi, lo = 0, 0
local HI, LO = {}, {}
local function blowup(n)
  if n % 2 == 1 then error({ kind = LO, value = n }) end
  error({ kind = HI, value = n })
end
local function lo_function(n)
  local ok, err = pcall(blowup, n)
  if not ok then
    if err.kind ~= LO then error(err, 0) end
    lo = lo + 1
  end
end
local function hi_function(n)
  local ok, err = pcall(lo_function, n)
  if not ok then
    if err.kind ~= HI then error(err, 0) end
    hi = hi + 1
  end
end
local n = tonumber(arg[1])
for i = n - 1, 0, -1 do hi_function(i) end
io.write(string.format("Exceptions: HI=%d / LO=%d\n", hi, lo))
