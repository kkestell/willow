/* Executable stub for `willow build`. The build appends the generated Lua to a
 * copy of this binary, followed by an 8-byte little-endian payload length and
 * the 8-byte magic "WILLOWLU". The stub reads its own file and runs the payload
 * with its command-line arguments. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static const char MAGIC[8] = "WILLOWLU";

static void die(const char *message) {
    fprintf(stderr, "error: %s\n", message);
    exit(1);
}

static void executable_path(char *path, size_t size) {
#ifdef __APPLE__
    uint32_t length = size;
    if (_NSGetExecutablePath(path, &length) != 0) die("cannot locate executable");
#else
    strcpy(path, "/proc/self/exe");
#endif
}

static char *read_payload(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (!file) die("cannot open executable");
    unsigned char trailer[16];
    if (fseek(file, -16, SEEK_END) != 0 || fread(trailer, 1, 16, file) != 16 ||
        memcmp(trailer + 8, MAGIC, 8) != 0) {
        die("executable has no program");
    }
    unsigned long long size = 0;
    for (int i = 7; i >= 0; i--) size = size << 8 | trailer[i];
    char *text = malloc(size);
    if (!text || fseek(file, -16 - (long)size, SEEK_END) != 0 || fread(text, 1, size, file) != size) {
        die("cannot read program");
    }
    fclose(file);
    *length = size;
    return text;
}

int main(int argc, char **argv) {
    char path[4096], resolved[4096];
    executable_path(path, sizeof path);
    if (!realpath(path, resolved)) die("cannot resolve executable path");
    size_t length;
    char *text = read_payload(resolved, &length);
    lua_State *L = luaL_newstate();
    if (!L) die("cannot create Lua state");
    luaL_openlibs(L);
    lua_createtable(L, argc - 1, 1);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, i == 0 ? resolved : argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");
    if (luaL_loadbuffer(L, text, length, "=program") != 0) {
        fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
        return 1;
    }
    /* The program's arguments are the chunk's varargs, as under luajit. */
    luaL_checkstack(L, argc, "too many arguments");
    for (int i = 1; i < argc; i++) lua_pushstring(L, argv[i]);
    if (lua_pcall(L, argc - 1, 0, 0) != 0) {
        fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
        return 1;
    }
    return 0;
}
