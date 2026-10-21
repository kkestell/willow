local n = tonumber(arg[1])
local ALU = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG" .. "GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA"
  .. "CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT" .. "ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA"
  .. "GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG" .. "AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC"
  .. "AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"
local IUB = {
  { "a", 0.27 }, { "c", 0.12 }, { "g", 0.12 }, { "t", 0.27 },
  { "B", 0.02 }, { "D", 0.02 }, { "H", 0.02 }, { "K", 0.02 }, { "M", 0.02 }, { "N", 0.02 },
  { "R", 0.02 }, { "S", 0.02 }, { "V", 0.02 }, { "W", 0.02 }, { "Y", 0.02 },
}
local HOMO_SAPIENS = { { "a", 0.3029549426680 }, { "c", 0.1979883004921 }, { "g", 0.1975473066391 }, { "t", 0.3015094502008 } }
local last = 42
local function random()
  last = (last * 3877 + 29573) % 139968
  return last / 139968
end
local function cumulative(entries)
  local result, total = {}, 0
  for i, entry in ipairs(entries) do
    total = total + entry[2]
    result[i] = { entry[1], total }
  end
  return result
end
local function repeat_fasta(header, sequence, count)
  io.write(header, "\n")
  local doubled, length, position = sequence .. sequence, #sequence, 0
  while count > 0 do
    local width = count < 60 and count or 60
    io.write(doubled:sub(position + 1, position + width), "\n")
    position = (position + width) % length
    count = count - width
  end
end
local function random_fasta(header, entries, count)
  io.write(header, "\n")
  local line = {}
  while count > 0 do
    local width = count < 60 and count or 60
    for i = 1, width do
      local r = random()
      local choice = entries[#entries][1]
      for _, entry in ipairs(entries) do
        if r < entry[2] then choice = entry[1]; break end
      end
      line[i] = choice
    end
    io.write(table.concat(line, "", 1, width), "\n")
    count = count - width
  end
end
repeat_fasta(">ONE Homo sapiens alu", ALU, 2 * n)
random_fasta(">TWO IUB ambiguity codes", cumulative(IUB), 3 * n)
random_fasta(">THREE Homo sapiens frequency", cumulative(HOMO_SAPIENS), 5 * n)
