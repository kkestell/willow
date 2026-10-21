#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct Toggle Toggle;
struct Toggle {
  bool state;
  int count_max, counter;
  Toggle *(*activate)(Toggle *);
  bool (*value)(Toggle *);
};
static Toggle *toggle_activate(Toggle *t) { t->state = !t->state; return t; }
static Toggle *nth_toggle_activate(Toggle *t) {
  if (++t->counter >= t->count_max) { t->state = !t->state; t->counter = 0; }
  return t;
}
static bool toggle_value(Toggle *t) { return t->state; }
static Toggle *new_toggle(bool state) {
  Toggle *t = malloc(sizeof *t);
  *t = (Toggle){ state, 0, 0, toggle_activate, toggle_value };
  return t;
}
static Toggle *new_nth_toggle(bool state, int count_max) {
  Toggle *t = malloc(sizeof *t);
  *t = (Toggle){ state, count_max, 0, nth_toggle_activate, toggle_value };
  return t;
}
static void run(Toggle *t, int n) {
  bool value = true;
  for (int i = 0; i < n; i++) { Toggle *a = t->activate(t); value = a->value(a); }
  puts(value ? "true" : "false");
}
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  run(new_toggle(true), n);
  run(new_nth_toggle(true, 3), n);
  return 0;
}
