#include <stdio.h>
#include <stdlib.h>
typedef struct Node { struct Node *left, *right; } Node;
static Node *make(int d) {
  Node *n = malloc(sizeof *n);
  if (d == 0) n->left = n->right = NULL; else { n->left = make(d - 1); n->right = make(d - 1); }
  return n;
}
static int check(Node *n) { return n->left ? 1 + check(n->left) + check(n->right) : 1; }
static void release(Node *n) { if (n->left) { release(n->left); release(n->right); } free(n); }
int main(int argc, char **argv) {
  int n = atoi(argv[1]), min_depth = 4, max_depth = n < min_depth + 2 ? min_depth + 2 : n;
  Node *s = make(max_depth + 1);
  printf("stretch tree of depth %d\t check: %d\n", max_depth + 1, check(s));
  release(s);
  Node *long_lived = make(max_depth);
  for (int d = min_depth; d <= max_depth; d += 2) {
    int iterations = 1 << (max_depth - d + min_depth), total = 0;
    for (int i = 0; i < iterations; i++) { Node *t = make(d); total += check(t); release(t); }
    printf("%d\t trees of depth %d\t check: %d\n", iterations, d, total);
  }
  printf("long lived tree of depth %d\t check: %d\n", max_depth, check(long_lived));
}
