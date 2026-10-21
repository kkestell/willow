#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
static int count_primes(int limit) {
  bool *flags = malloc(limit);
  for (int i = 0; i < limit; i++) flags[i] = true;
  int count = 0;
  for (int i = 2; i < limit; i++) {
    if (flags[i]) {
      count++;
      for (int j = i + i; j < limit; j += i) flags[j] = false;
    }
  }
  free(flags);
  return count;
}
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  for (int i = 0; i < 3; i++) {
    int limit = 10000 << (n - i);
    printf("Primes up to %8d %8d\n", limit, count_primes(limit));
  }
  return 0;
}
