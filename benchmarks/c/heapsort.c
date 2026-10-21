#include <stdio.h>
#include <stdlib.h>
static double random_float(double maximum) {
  static long last = 42;
  last = (last * 3877 + 29573) % 139968;
  return maximum * last / 139968;
}
static void heap_sort(int n, double *items) {
  int ir = n, l = n / 2 + 1, i, j;
  double rra;
  for (;;) {
    if (l > 1) {
      rra = items[--l];
    } else {
      rra = items[ir];
      items[ir] = items[1];
      if (--ir == 1) { items[1] = rra; return; }
    }
    i = l;
    j = l * 2;
    while (j <= ir) {
      if (j < ir && items[j] < items[j + 1]) j++;
      if (rra < items[j]) {
        items[i] = items[j];
        i = j;
        j += i;
      } else {
        j = ir + 1;
      }
    }
    items[i] = rra;
  }
}
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  double *items = malloc((n + 1) * sizeof *items);
  for (int i = 1; i <= n; i++) items[i] = random_float(1.0);
  heap_sort(n, items);
  printf("%.10f\n", items[n]);
  free(items);
  return 0;
}
