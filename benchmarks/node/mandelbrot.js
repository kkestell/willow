const n = +process.argv[2];
let checksum = 0;
for (let y = 0; y < n; y++) {
  const ci = 2 * y / n - 1;
  let byte = 0, bits = 0;
  for (let x = 0; x < n; x++) {
    const cr = 2 * x / n - 1.5;
    let zr = 0, zi = 0, zr2 = 0, zi2 = 0, i = 0;
    while (i < 50 && zr2 + zi2 <= 4) {
      zi = 2 * zr * zi + ci;
      zr = zr2 - zi2 + cr;
      zr2 = zr * zr;
      zi2 = zi * zi;
      i++;
    }
    byte *= 2;
    if (zr2 + zi2 <= 4) byte += 1;
    bits++;
    if (bits === 8) { checksum = (checksum * 31 + byte) % 1000000007; byte = 0; bits = 0; }
  }
  if (bits !== 0) {
    while (bits < 8) { byte *= 2; bits++; }
    checksum = (checksum * 31 + byte) % 1000000007;
  }
}
console.log(checksum);
