local n = tonumber(arg[1])
local SYMBOLS = { "A", "C", "G", "T" }
local PROBABILITIES = { 0.3029549426680, 0.1979883004921, 0.1975473066391, 0.3015094502008 }
local function generate(count)
  local cumulative, total = {}, 0
  for i, p in ipairs(PROBABILITIES) do total = total + p; cumulative[i] = total end
  local chars, last = {}, 42
  for i = 1, count do
    last = (last * 3877 + 29573) % 139968
    local r = last / 139968
    local choice = 4
    for j = 1, 4 do
      if r < cumulative[j] then choice = j; break end
    end
    chars[i] = SYMBOLS[choice]
  end
  return table.concat(chars)
end
local function count(sequence, k)
  local counts = {}
  for i = 1, #sequence - k + 1 do
    local kmer = sequence:sub(i, i + k - 1)
    counts[kmer] = (counts[kmer] or 0) + 1
  end
  return counts
end
local function print_frequencies(sequence, k)
  local counts, kmers = count(sequence, k), {}
  for kmer in pairs(counts) do kmers[#kmers + 1] = kmer end
  table.sort(kmers, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  local total = #sequence - k + 1
  for _, kmer in ipairs(kmers) do io.write(string.format("%s %.3f\n", kmer, 100 * counts[kmer] / total)) end
  io.write("\n")
end
local function print_count(sequence, kmer)
  io.write(count(sequence, #kmer)[kmer] or 0, "\t", kmer, "\n")
end
local sequence = generate(n)
print_frequencies(sequence, 1)
print_frequencies(sequence, 2)
for _, kmer in ipairs({ "GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT" }) do print_count(sequence, kmer) end
