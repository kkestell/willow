#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* An open-addressing hash table from short strings to integers, sized so that
   it never needs to grow. */
typedef struct { char key[16]; int value; int used; } Slot;
typedef struct { Slot slots[32768]; } Table;
#define MASK 32767
static Slot *lookup(Table *table, const char *key) {
  uint64_t hash = 14695981039346656037ULL;
  for (const char *c = key; *c; c++) { hash ^= (unsigned char)*c; hash *= 1099511628211ULL; }
  size_t i = hash & MASK;
  for (;;) {
    Slot *slot = &table->slots[i];
    if (!slot->used || strcmp(slot->key, key) == 0) return slot;
    i = (i + 1) & MASK;
  }
}
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  Table *first = calloc(1, sizeof *first), *second = calloc(1, sizeof *second);
  for (int i = 0; i < 10000; i++) {
    char key[16];
    snprintf(key, sizeof key, "foo_%d", i);
    Slot *slot = lookup(first, key);
    strcpy(slot->key, key);
    slot->value = i;
    slot->used = 1;
  }
  for (int i = 0; i < n; i++) {
    for (int s = 0; s <= MASK; s++) {
      Slot *from = &first->slots[s];
      if (!from->used) continue;
      Slot *to = lookup(second, from->key);
      if (!to->used) { strcpy(to->key, from->key); to->used = 1; }
      to->value += from->value;
    }
  }
  printf("%d %d %d %d\n", lookup(first, "foo_1")->value, lookup(first, "foo_9999")->value,
         lookup(second, "foo_1")->value, lookup(second, "foo_9999")->value);
  return 0;
}
