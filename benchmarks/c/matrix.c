#include <stdio.h>
#include <stdlib.h>
#define SIZE 30
static int **make_matrix(int rows, int columns) {
  int **matrix = malloc(rows * sizeof *matrix), count = 1;
  for (int i = 0; i < rows; i++) {
    matrix[i] = malloc(columns * sizeof **matrix);
    for (int j = 0; j < columns; j++) matrix[i][j] = count++;
  }
  return matrix;
}
static void free_matrix(int rows, int **matrix) {
  for (int i = 0; i < rows; i++) free(matrix[i]);
  free(matrix);
}
static int **multiply(int rows, int columns, int **a, int **b) {
  int **product = malloc(rows * sizeof *product);
  for (int i = 0; i < rows; i++) {
    product[i] = malloc(columns * sizeof **product);
    for (int j = 0; j < columns; j++) {
      int total = 0;
      for (int k = 0; k < columns; k++) total += a[i][k] * b[k][j];
      product[i][j] = total;
    }
  }
  return product;
}
int main(int argc, char **argv) {
  int n = atoi(argv[1]);
  int **a = make_matrix(SIZE, SIZE), **b = make_matrix(SIZE, SIZE), **product = NULL;
  for (int i = 0; i < n; i++) {
    if (product) free_matrix(SIZE, product);
    product = multiply(SIZE, SIZE, a, b);
  }
  printf("%d %d %d %d\n", product[0][0], product[2][3], product[3][2], product[4][4]);
  return 0;
}
