#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char SYMBOLS[] = "ACGT";
static const double PROBABILITIES[] = { 0.3029549426680, 0.1979883004921, 0.1975473066391, 0.3015094502008 };
static char *generate(int n) {
  double cumulative[4], total = 0;
  for (int i = 0; i < 4; i++) { total += PROBABILITIES[i]; cumulative[i] = total; }
  char *sequence = malloc(n + 1);
  int last = 42;
  for (int i = 0; i < n; i++) {
    last = (last * 3877 + 29573) % 139968;
    double r = last / 139968.0;
    int choice = 3;
    for (int j = 0; j < 4; j++) {
      if (r < cumulative[j]) { choice = j; break; }
    }
    sequence[i] = SYMBOLS[choice];
  }
  sequence[n] = '\0';
  return sequence;
}
/* An open-addressing hash table from k-mers of at most 18 characters to counts,
   sized so that it never needs to grow. */
typedef struct { char key[19]; int count; } Slot;
typedef struct { Slot *slots; size_t mask; } Table;
static Slot *lookup(Table *table, const char *key, int k) {
  uint64_t hash = 14695981039346656037ULL;
  for (int i = 0; i < k; i++) { hash ^= (unsigned char)key[i]; hash *= 1099511628211ULL; }
  size_t i = hash & table->mask;
  for (;;) {
    Slot *slot = &table->slots[i];
    if (slot->count == 0 || memcmp(slot->key, key, k) == 0) return slot;
    i = (i + 1) & table->mask;
  }
}
static Table count(const char *sequence, int length, int k) {
  size_t capacity = 1024;
  while (capacity < 2 * (size_t)length) capacity *= 2;
  Table table = { calloc(capacity, sizeof(Slot)), capacity - 1 };
  for (int i = 0; i + k <= length; i++) {
    Slot *slot = lookup(&table, sequence + i, k);
    if (slot->count == 0) memcpy(slot->key, sequence + i, k);
    slot->count++;
  }
  return table;
}
static int by_count_then_key(const void *a, const void *b) {
  const Slot *x = a, *y = b;
  if (x->count != y->count) return y->count - x->count;
  return strcmp(x->key, y->key);
}
static void print_frequencies(const char *sequence, int length, int k) {
  Table table = count(sequence, length, k);
  size_t used = 0;
  for (size_t i = 0; i <= table.mask; i++) {
    if (table.slots[i].count != 0) table.slots[used++] = table.slots[i];
  }
  qsort(table.slots, used, sizeof(Slot), by_count_then_key);
  for (size_t i = 0; i < used; i++) printf("%s %.3f\n", table.slots[i].key, 100.0 * table.slots[i].count / (length - k + 1));
  putchar('\n');
  free(table.slots);
}
static void print_count(const char *sequence, int length, const char *kmer) {
  Table table = count(sequence, length, strlen(kmer));
  printf("%d\t%s\n", lookup(&table, kmer, strlen(kmer))->count, kmer);
  free(table.slots);
}
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  char *sequence = generate(n);
  print_frequencies(sequence, n, 1);
  print_frequencies(sequence, n, 2);
  const char *kmers[] = { "GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT" };
  for (int i = 0; i < 5; i++) print_count(sequence, n, kmers[i]);
  free(sequence);
  return 0;
}
