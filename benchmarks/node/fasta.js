const ALU = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG" + "GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA"
  + "CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT" + "ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA"
  + "GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG" + "AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC"
  + "AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA";
const IUB = [["a", 0.27], ["c", 0.12], ["g", 0.12], ["t", 0.27], ["B", 0.02], ["D", 0.02], ["H", 0.02], ["K", 0.02],
  ["M", 0.02], ["N", 0.02], ["R", 0.02], ["S", 0.02], ["V", 0.02], ["W", 0.02], ["Y", 0.02]];
const HOMO_SAPIENS = [["a", 0.3029549426680], ["c", 0.1979883004921], ["g", 0.1975473066391], ["t", 0.3015094502008]];
let last = 42;
function random() {
  last = (last * 3877 + 29573) % 139968;
  return last / 139968;
}
function cumulative(table) {
  const result = [];
  let total = 0;
  for (const [symbol, probability] of table) { total += probability; result.push([symbol, total]); }
  return result;
}
const chunks = [];
function write(text) {
  chunks.push(text);
  if (chunks.length === 4096) { process.stdout.write(chunks.join("")); chunks.length = 0; }
}
function repeatFasta(header, sequence, count) {
  write(header + "\n");
  const doubled = sequence + sequence, length = sequence.length;
  let position = 0;
  while (count > 0) {
    const width = Math.min(count, 60);
    write(doubled.slice(position, position + width) + "\n");
    position = (position + width) % length;
    count -= width;
  }
}
function randomFasta(header, table, count) {
  write(header + "\n");
  while (count > 0) {
    const width = Math.min(count, 60);
    const line = [];
    for (let i = 0; i < width; i++) {
      const r = random();
      let choice = table[table.length - 1][0];
      for (const [symbol, probability] of table) {
        if (r < probability) { choice = symbol; break; }
      }
      line.push(choice);
    }
    write(line.join("") + "\n");
    count -= width;
  }
}
const n = +process.argv[2];
repeatFasta(">ONE Homo sapiens alu", ALU, 2 * n);
randomFasta(">TWO IUB ambiguity codes", cumulative(IUB), 3 * n);
randomFasta(">THREE Homo sapiens frequency", cumulative(HOMO_SAPIENS), 5 * n);
process.stdout.write(chunks.join(""));
