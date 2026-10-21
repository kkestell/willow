local COMPLEMENTS = {}
local codes, paired = "ACBDGHKMNSRUTWVYacbdghkmnsrutwvy", "TGVHCDMKNSYAAWBRTGVHCDMKNSYAAWBR"
for i = 1, #codes do COMPLEMENTS[codes:sub(i, i)] = paired:sub(i, i) end
local function write_reversed(lines)
  local sequence = table.concat(lines):reverse():gsub(".", COMPLEMENTS)
  for i = 1, #sequence, 60 do io.write(sequence:sub(i, i + 59), "\n") end
end
local lines = {}
for line in io.lines() do
  if line:sub(1, 1) == ">" then
    write_reversed(lines)
    lines = {}
    io.write(line, "\n")
  else
    lines[#lines + 1] = line
  end
end
write_reversed(lines)
