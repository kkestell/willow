#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  long checksum = 0;
  for (int y = 0; y < n; y++) {
    double ci = 2.0 * y / n - 1.0;
    int byte = 0, bits = 0;
    for (int x = 0; x < n; x++) {
      double cr = 2.0 * x / n - 1.5;
      double zr = 0, zi = 0, zr2 = 0, zi2 = 0;
      int i = 0;
      while (i < 50 && zr2 + zi2 <= 4.0) {
        zi = 2.0 * zr * zi + ci;
        zr = zr2 - zi2 + cr;
        zr2 = zr * zr;
        zi2 = zi * zi;
        i++;
      }
      byte *= 2;
      if (zr2 + zi2 <= 4.0) byte += 1;
      if (++bits == 8) { checksum = (checksum * 31 + byte) % 1000000007; byte = 0; bits = 0; }
    }
    if (bits != 0) {
      while (bits < 8) { byte *= 2; bits++; }
      checksum = (checksum * 31 + byte) % 1000000007;
    }
  }
  printf("%ld\n", checksum);
  return 0;
}
