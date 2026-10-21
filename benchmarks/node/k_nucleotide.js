const SYMBOLS = "ACGT";
const PROBABILITIES = [0.3029549426680, 0.1979883004921, 0.1975473066391, 0.3015094502008];
function generate(n) {
  const cumulative = [];
  let total = 0;
  for (const p of PROBABILITIES) { total += p; cumulative.push(total); }
  const chars = [];
  let last = 42;
  for (let i = 0; i < n; i++) {
    last = (last * 3877 + 29573) % 139968;
    const r = last / 139968;
    let choice = 3;
    for (let j = 0; j < 4; j++) {
      if (r < cumulative[j]) { choice = j; break; }
    }
    chars.push(SYMBOLS[choice]);
  }
  return chars.join("");
}
function count(sequence, k) {
  const counts = new Map();
  for (let i = 0; i + k <= sequence.length; i++) {
    const kmer = sequence.slice(i, i + k);
    counts.set(kmer, (counts.get(kmer) || 0) + 1);
  }
  return counts;
}
const lines = [];
function printFrequencies(sequence, k) {
  const counts = count(sequence, k);
  const total = sequence.length - k + 1;
  const kmers = [...counts.keys()].sort((a, b) => counts.get(b) - counts.get(a) || (a < b ? -1 : 1));
  for (const kmer of kmers) lines.push(`${kmer} ${(100 * counts.get(kmer) / total).toFixed(3)}`);
  lines.push("");
}
function printCount(sequence, kmer) {
  lines.push(`${count(sequence, kmer.length).get(kmer) || 0}\t${kmer}`);
}
const sequence = generate(+process.argv[2]);
printFrequencies(sequence, 1);
printFrequencies(sequence, 2);
for (const kmer of ["GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"]) printCount(sequence, kmer);
console.log(lines.join("\n"));
