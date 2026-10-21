#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct { double x, y, z; } Vec;
typedef struct { Vec center; double radius; } Sphere;
/* A scene is a sphere when it has no children, and otherwise a group whose
   sphere bounds the children. */
typedef struct Scene { Sphere sphere; int count; struct Scene **children; } Scene;
typedef struct { double distance; Vec normal; } Hit;
static Vec vec(double x, double y, double z) { return (Vec){ x, y, z }; }
static Vec add(Vec a, Vec b) { return vec(a.x + b.x, a.y + b.y, a.z + b.z); }
static Vec sub(Vec a, Vec b) { return vec(a.x - b.x, a.y - b.y, a.z - b.z); }
static Vec scale(double s, Vec v) { return vec(s * v.x, s * v.y, s * v.z); }
static double dot(Vec a, Vec b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static Vec unitise(Vec v) { return scale(1.0 / sqrt(dot(v, v)), v); }
static double ray_sphere(const Sphere *sphere, Vec origin, Vec direction) {
  Vec v = sub(sphere->center, origin);
  double b = dot(v, direction), disc = b * b - dot(v, v) + sphere->radius * sphere->radius;
  if (disc < 0.0) return INFINITY;
  double d = sqrt(disc), t2 = b + d;
  if (t2 < 0.0) return INFINITY;
  double t1 = b - d;
  return t1 > 0.0 ? t1 : t2;
}
static void intersect(const Scene *scene, Vec origin, Vec direction, Hit *hit) {
  double distance = ray_sphere(&scene->sphere, origin, direction);
  if (distance >= hit->distance) return;
  if (scene->count == 0) {
    hit->distance = distance;
    hit->normal = unitise(sub(add(origin, scale(distance, direction)), scene->sphere.center));
    return;
  }
  for (int i = 0; i < scene->count; i++) intersect(scene->children[i], origin, direction, hit);
}
static int shadowed(const Scene *scene, Vec origin, Vec direction) {
  if (!(ray_sphere(&scene->sphere, origin, direction) < INFINITY)) return 0;
  if (scene->count == 0) return 1;
  for (int i = 0; i < scene->count; i++) {
    if (shadowed(scene->children[i], origin, direction)) return 1;
  }
  return 0;
}
static double ray_trace(Vec light, Vec origin, Vec direction, const Scene *scene) {
  Hit hit = { INFINITY, vec(0.0, 0.0, 0.0) };
  intersect(scene, origin, direction, &hit);
  if (hit.distance == INFINITY) return 0.0;
  double g = dot(hit.normal, light);
  if (g >= 0.0) return 0.0;
  Vec point = add(add(origin, scale(hit.distance, direction)), scale(sqrt(DBL_EPSILON), hit.normal));
  return shadowed(scene, point, scale(-1.0, light)) ? 0.0 : -g;
}
static Scene *create(int level, Vec center, double radius) {
  Scene *scene = calloc(1, sizeof *scene);
  scene->sphere = (Sphere){ center, radius };
  if (level == 1) return scene;
  Scene *group = malloc(sizeof *group);
  group->sphere = (Sphere){ center, 3.0 * radius };
  group->count = 5;
  group->children = malloc(5 * sizeof *group->children);
  group->children[0] = scene;
  double offset = 3.0 * radius / sqrt(12.0);
  int i = 1;
  for (int dz = -1; dz <= 1; dz += 2) {
    for (int dx = -1; dx <= 1; dx += 2) {
      group->children[i++] = create(level - 1, add(center, scale(offset, vec(dx, 1.0, dz))), 0.5 * radius);
    }
  }
  return group;
}
int main(int argc, char **argv) {
  int n = atoi(argv[1]), samples = 4;
  Vec light = unitise(vec(-1.0, -3.0, 2.0)), eye = vec(0.0, 0.0, -4.0);
  Scene *scene = create(6, vec(0.0, -1.0, 0.0), 1.0);
  printf("P5\n%d %d\n255\n", n, n);
  for (int y = n - 1; y >= 0; y--) {
    for (int x = 0; x < n; x++) {
      double g = 0.0;
      for (int dx = 0; dx < samples; dx++) {
        for (int dy = 0; dy < samples; dy++) {
          Vec direction = unitise(vec(x + (double)dx / samples - n / 2.0, y + (double)dy / samples - n / 2.0, n));
          g += ray_trace(light, eye, direction, scene);
        }
      }
      putchar((int)(0.5 + 255.0 * g / (samples * samples)));
    }
  }
  return 0;
}
