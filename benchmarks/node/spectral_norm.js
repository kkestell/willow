const a = (i, j) => 1 / (((i + j) * (i + j + 1)) / 2 + i + 1);
function times(v, out) { const n = v.length; for (let i = 0; i < n; i++) { let t = 0; for (let j = 0; j < n; j++) t += a(i, j) * v[j]; out[i] = t; } }
function timesT(v, out) { const n = v.length; for (let i = 0; i < n; i++) { let t = 0; for (let j = 0; j < n; j++) t += a(j, i) * v[j]; out[i] = t; } }
const n = +process.argv[2];
const u = new Array(n).fill(1), v = new Array(n).fill(0), s = new Array(n).fill(0);
for (let i = 0; i < 10; i++) { times(u, s); timesT(s, v); times(v, s); timesT(s, u); }
let vbv = 0, vv = 0;
for (let i = 0; i < n; i++) { vbv += u[i] * v[i]; vv += v[i] * v[i]; }
console.log(Math.sqrt(vbv / vv).toFixed(9));
