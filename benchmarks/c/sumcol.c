#include <stdio.h>
#include <stdlib.h>
int main(void) {
  char line[128];
  long long total = 0;
  while (fgets(line, sizeof line, stdin)) total += atoll(line);
  printf("%lld\n", total);
  return 0;
}
