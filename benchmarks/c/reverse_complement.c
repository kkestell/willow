#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static char complements[256];
static char *sequence;
static size_t length, capacity;
static void write_reversed(void) {
  for (size_t i = 0, j = length; i < j; ) {
    char c = complements[(unsigned char)sequence[i]];
    sequence[i++] = complements[(unsigned char)sequence[--j]];
    sequence[j] = c;
  }
  for (size_t i = 0; i < length; i += 60) {
    size_t width = length - i < 60 ? length - i : 60;
    fwrite(sequence + i, 1, width, stdout);
    putchar('\n');
  }
  length = 0;
}
int main(void) {
  const char *codes = "ACBDGHKMNSRUTWVYacbdghkmnsrutwvy", *paired = "TGVHCDMKNSYAAWBRTGVHCDMKNSYAAWBR";
  for (int i = 0; codes[i]; i++) complements[(unsigned char)codes[i]] = paired[i];
  capacity = 1 << 16;
  sequence = malloc(capacity);
  char line[4096];
  while (fgets(line, sizeof line, stdin)) {
    if (line[0] == '>') {
      write_reversed();
      fputs(line, stdout);
      continue;
    }
    size_t width = strcspn(line, "\n");
    if (length + width > capacity) {
      while (length + width > capacity) capacity *= 2;
      sequence = realloc(sequence, capacity);
    }
    memcpy(sequence + length, line, width);
    length += width;
  }
  write_reversed();
  return 0;
}
