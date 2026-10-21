#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int hi, lo;
static jmp_buf hi_exception, lo_exception;
static void blowup(int n) {
  if (n % 2 == 1) longjmp(lo_exception, 1);
  longjmp(hi_exception, 1);
}
static void lo_function(volatile int n) {
  jmp_buf saved;
  memcpy(saved, lo_exception, sizeof saved);
  if (setjmp(lo_exception) == 0) blowup(n); else lo++;
  memcpy(lo_exception, saved, sizeof saved);
}
static void hi_function(volatile int n) {
  jmp_buf saved;
  memcpy(saved, hi_exception, sizeof saved);
  if (setjmp(hi_exception) == 0) lo_function(n); else hi++;
  memcpy(hi_exception, saved, sizeof saved);
}
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  for (int i = n - 1; i >= 0; i--) hi_function(i);
  printf("Exceptions: HI=%d / LO=%d\n", hi, lo);
  return 0;
}
