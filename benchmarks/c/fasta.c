#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char ALU[] =
  "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG" "GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA"
  "CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT" "ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA"
  "GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG" "AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC"
  "AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA";
typedef struct { char symbol; double probability; } Entry;
static Entry IUB[] = {
  { 'a', 0.27 }, { 'c', 0.12 }, { 'g', 0.12 }, { 't', 0.27 }, { 'B', 0.02 }, { 'D', 0.02 }, { 'H', 0.02 }, { 'K', 0.02 },
  { 'M', 0.02 }, { 'N', 0.02 }, { 'R', 0.02 }, { 'S', 0.02 }, { 'V', 0.02 }, { 'W', 0.02 }, { 'Y', 0.02 },
};
static Entry HOMO_SAPIENS[] = { { 'a', 0.3029549426680 }, { 'c', 0.1979883004921 }, { 'g', 0.1975473066391 }, { 't', 0.3015094502008 } };
static int last = 42;
static double random_float(void) {
  last = (last * 3877 + 29573) % 139968;
  return last / 139968.0;
}
static void cumulative(Entry *table, int size) {
  double total = 0;
  for (int i = 0; i < size; i++) { total += table[i].probability; table[i].probability = total; }
}
static void repeat_fasta(const char *header, const char *sequence, int count) {
  int length = strlen(sequence);
  char *doubled = malloc(2 * length);
  memcpy(doubled, sequence, length);
  memcpy(doubled + length, sequence, length);
  puts(header);
  int position = 0;
  while (count > 0) {
    int width = count < 60 ? count : 60;
    fwrite(doubled + position, 1, width, stdout);
    putchar('\n');
    position = (position + width) % length;
    count -= width;
  }
  free(doubled);
}
static void random_fasta(const char *header, Entry *table, int size, int count) {
  char line[61];
  puts(header);
  while (count > 0) {
    int width = count < 60 ? count : 60;
    for (int i = 0; i < width; i++) {
      double r = random_float();
      char choice = table[size - 1].symbol;
      for (int j = 0; j < size; j++) {
        if (r < table[j].probability) { choice = table[j].symbol; break; }
      }
      line[i] = choice;
    }
    line[width] = '\n';
    fwrite(line, 1, width + 1, stdout);
    count -= width;
  }
}
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  int iub = sizeof IUB / sizeof IUB[0], homo = sizeof HOMO_SAPIENS / sizeof HOMO_SAPIENS[0];
  cumulative(IUB, iub);
  cumulative(HOMO_SAPIENS, homo);
  repeat_fasta(">ONE Homo sapiens alu", ALU, 2 * n);
  random_fasta(">TWO IUB ambiguity codes", IUB, iub, 3 * n);
  random_fasta(">THREE Homo sapiens frequency", HOMO_SAPIENS, homo, 5 * n);
  return 0;
}
