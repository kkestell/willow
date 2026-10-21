#include <stdio.h>
#include <stdlib.h>
static int ack(int m, int n) {
  if (m == 0) return n + 1;
  if (n == 0) return ack(m - 1, 1);
  return ack(m - 1, ack(m, n - 1));
}
static int fib(int n) { return n < 2 ? 1 : fib(n - 2) + fib(n - 1); }
static double fib_float(double n) { return n < 2.0 ? 1.0 : fib_float(n - 2.0) + fib_float(n - 1.0); }
static int tak(int x, int y, int z) { return y < x ? tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y)) : z; }
static double tak_float(double x, double y, double z) {
  return y < x ? tak_float(tak_float(x - 1.0, y, z), tak_float(y - 1.0, z, x), tak_float(z - 1.0, x, y)) : z;
}
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  printf("Ack(3,%d): %d\n", n + 1, ack(3, n + 1));
  printf("Fib(%.1f): %.1f\n", 27.0 + n, fib_float(27.0 + n));
  printf("Tak(%d,%d,%d): %d\n", 3 * n, 2 * n, n, tak(3 * n, 2 * n, n));
  printf("Fib(3): %d\n", fib(3));
  printf("Tak(3.0,2.0,1.0): %.1f\n", tak_float(3.0, 2.0, 1.0));
  return 0;
}
