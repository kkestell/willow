#include "willow0.h"

#include <assert.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void *xmalloc(size_t size) {
    void *data = malloc(size ? size : 1);
    if (!data) {
        fatal(STR("willow0: out of memory"));
    }
    return data;
}

void *xrealloc(void *data, size_t size) {
    void *grown = realloc(data, size ? size : 1);
    if (!grown) {
        fatal(STR("willow0: out of memory"));
    }
    return grown;
}

void *box_copy(const void *value, size_t size) {
    void *copy = xmalloc(size);
    memcpy(copy, value, size);
    return copy;
}

void *array_grow(void *data, size_t *cap, size_t needed, size_t element_size) {
    if (needed <= *cap) {
        return data;
    }
    size_t grown = *cap ? *cap : 8;
    while (grown < needed) {
        grown *= 2;
    }
    data = xrealloc(data, grown * element_size);
    *cap = grown;
    return data;
}

void *array_copy(const void *data, size_t len, size_t element_size) {
    if (!len) {
        return NULL;
    }
    return box_copy(data, len * element_size);
}

String str_from_cstr(const char *text) {
    return (String){text, strlen(text)};
}

String str_copy(const char *data, size_t len) {
    char *copy = xmalloc(len + 1);
    if (len) {
        memcpy(copy, data, len);
    }
    copy[len] = '\0';
    return (String){copy, len};
}

bool str_equal(String left, String right) {
    return left.len == right.len &&
        (!left.len || memcmp(left.data, right.data, left.len) == 0);
}

int str_compare(String left, String right) {
    size_t len = left.len < right.len ? left.len : right.len;
    int cmp = len ? memcmp(left.data, right.data, len) : 0;
    if (cmp) {
        return (cmp > 0) - (cmp < 0);
    }
    return (left.len > right.len) - (left.len < right.len);
}

static void sb_reserve(StringBuilder *out, size_t extra) {
    out->data = array_grow(out->data, &out->cap, out->len + extra + 1, 1);
}

void sb_append(StringBuilder *out, String text) {
    sb_reserve(out, text.len);
    if (text.len) {
        memcpy(out->data + out->len, text.data, text.len);
    }
    out->len += text.len;
    out->data[out->len] = '\0';
}

void sb_push_byte(StringBuilder *out, unsigned char byte) {
    sb_reserve(out, 1);
    out->data[out->len++] = (char)byte;
    out->data[out->len] = '\0';
}

void sb_push_char(StringBuilder *out, uint32_t code) {
    assert(code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff));
    if (code < 0x80) {
        sb_push_byte(out, (unsigned char)code);
    } else if (code < 0x800) {
        sb_push_byte(out, (unsigned char)(0xc0 | (code >> 6)));
        sb_push_byte(out, (unsigned char)(0x80 | (code & 0x3f)));
    } else if (code < 0x10000) {
        sb_push_byte(out, (unsigned char)(0xe0 | (code >> 12)));
        sb_push_byte(out, (unsigned char)(0x80 | ((code >> 6) & 0x3f)));
        sb_push_byte(out, (unsigned char)(0x80 | (code & 0x3f)));
    } else {
        sb_push_byte(out, (unsigned char)(0xf0 | (code >> 18)));
        sb_push_byte(out, (unsigned char)(0x80 | ((code >> 12) & 0x3f)));
        sb_push_byte(out, (unsigned char)(0x80 | ((code >> 6) & 0x3f)));
        sb_push_byte(out, (unsigned char)(0x80 | (code & 0x3f)));
    }
}

static void sb_vprintf(StringBuilder *out, const char *format, va_list args) {
    va_list measure;
    va_copy(measure, args);
    int len = vsnprintf(NULL, 0, format, measure);
    va_end(measure);
    if (len < 0) {
        fatal(STR("willow0: cannot format string"));
    }
    sb_reserve(out, (size_t)len);
    int written = vsnprintf(out->data + out->len, out->cap - out->len, format, args);
    if (written != len) {
        fatal(STR("willow0: cannot format string"));
    }
    out->len += (size_t)len;
}

void sb_printf(StringBuilder *out, const char *format, ...) {
    va_list args;
    va_start(args, format);
    sb_vprintf(out, format, args);
    va_end(args);
}

String sb_finish(StringBuilder *out) {
    String text = out->data ? (String){out->data, out->len} : STR("");
    *out = (StringBuilder){0};
    return text;
}

String str_format(const char *format, ...) {
    StringBuilder out = {0};
    va_list args;
    va_start(args, format);
    sb_vprintf(&out, format, args);
    va_end(args);
    return sb_finish(&out);
}

bool utf8_decode(String text, size_t *at, uint32_t *code) {
    if (*at >= text.len) {
        return false;
    }
    const unsigned char *bytes = (const unsigned char *)text.data + *at;
    uint32_t value = bytes[0];
    size_t width;
    uint32_t min;
    if (value < 0x80) {
        width = 1;
        min = 0;
    } else if (value >= 0xc2 && value <= 0xdf) {
        width = 2;
        min = 0x80;
        value &= 0x1f;
    } else if (value >= 0xe0 && value <= 0xef) {
        width = 3;
        min = 0x800;
        value &= 0x0f;
    } else if (value >= 0xf0 && value <= 0xf4) {
        width = 4;
        min = 0x10000;
        value &= 0x07;
    } else {
        return false;
    }
    if (width > text.len - *at) {
        return false;
    }
    for (size_t i = 1; i < width; i++) {
        if ((bytes[i] & 0xc0) != 0x80) {
            return false;
        }
        value = (value << 6) | (bytes[i] & 0x3f);
    }
    if (value < min || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) {
        return false;
    }
    *at += width;
    *code = value;
    return true;
}

static uint64_t str_hash(String key) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < key.len; i++) {
        hash ^= (unsigned char)key.data[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static size_t map_slot(const Map *map, String key) {
    size_t slot = (size_t)str_hash(key) & (map->cap - 1);
    while (map->entries[slot].occupied && !str_equal(map->entries[slot].key, key)) {
        slot = (slot + 1) & (map->cap - 1);
    }
    return slot;
}

void *map_get(const Map *map, String key) {
    if (!map->cap) {
        return NULL;
    }
    const MapEntry *entry = &map->entries[map_slot(map, key)];
    return entry->occupied ? entry->value : NULL;
}

bool map_contains(const Map *map, String key) {
    return map_get(map, key) != NULL;
}

static void map_grow(Map *map) {
    size_t cap = map->cap ? map->cap * 2 : 16;
    Map grown = {xmalloc(cap * sizeof(MapEntry)), map->len, cap};
    memset(grown.entries, 0, cap * sizeof(MapEntry));
    for (size_t i = 0; i < map->cap; i++) {
        if (map->entries[i].occupied) {
            grown.entries[map_slot(&grown, map->entries[i].key)] = map->entries[i];
        }
    }
    *map = grown;
}

bool map_insert(Map *map, String key, void *value) {
    assert(value != NULL);
    if (!map->cap || map->len >= map->cap / 2) {
        map_grow(map);
    }
    MapEntry *entry = &map->entries[map_slot(map, key)];
    if (entry->occupied) {
        entry->value = value;
        return false;
    }
    *entry = (MapEntry){true, key, value};
    map->len++;
    return true;
}

Map map_clone(const Map *map) {
    Map copy = *map;
    copy.entries = array_copy(map->entries, map->cap, sizeof(MapEntry));
    return copy;
}

static void write_string(FILE *out, String text) {
    if (text.len) {
        fwrite(text.data, 1, text.len, out);
    }
}

_Noreturn void fail(String path, Pos pos, String message) {
    write_string(stderr, path);
    fprintf(stderr, ":%" PRIu32 ":%" PRIu32 ": error: ", pos.line, pos.col);
    write_string(stderr, message);
    fputc('\n', stderr);
    exit(1);
}

_Noreturn void fatal(String message) {
    write_string(stderr, message);
    fputc('\n', stderr);
    exit(1);
}

String io_error(int error) {
    return str_format("%s (os error %d)", strerror(error), error);
}
