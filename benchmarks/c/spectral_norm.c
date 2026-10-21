#include <math.h>
#include <stdio.h>
#include <stdlib.h>
static double a(int i, int j) { return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1); }
static void times(int n, const double *v, double *out) {
  for (int i = 0; i < n; i++) { double t = 0; for (int j = 0; j < n; j++) t += a(i, j) * v[j]; out[i] = t; }
}
static void times_t(int n, const double *v, double *out) {
  for (int i = 0; i < n; i++) { double t = 0; for (int j = 0; j < n; j++) t += a(j, i) * v[j]; out[i] = t; }
}
static void ata(int n, const double *v, double *out, double *s) { times(n, v, s); times_t(n, s, out); }
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  double *u = malloc(n * sizeof *u), *v = malloc(n * sizeof *v), *s = malloc(n * sizeof *s);
  for (int i = 0; i < n; i++) u[i] = 1;
  for (int i = 0; i < 10; i++) { ata(n, u, v, s); ata(n, v, u, s); }
  double vbv = 0, vv = 0;
  for (int i = 0; i < n; i++) { vbv += u[i] * v[i]; vv += v[i] * v[i]; }
  printf("%.9f\n", sqrt(vbv / vv));
}
