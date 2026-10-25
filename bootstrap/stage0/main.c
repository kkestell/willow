/* Stage 0 of the Willow bootstrap. */
#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#include "willow0.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/* The core module, compiled into every program. */
static const char CORE[] =
#include "../../build/stage0/core.inc"
;
static const char *const CORE_PATH = "bootstrap/core/core.wlo";
static bool legacy_syntax;

static const char *const USAGE =
    "usage: willow0 [--legacy] build FILE.wlo -o OUTPUT\n"
    "       willow0 [--legacy] compile FILE.wlo -o OUTPUT.ssa";

static Module load(String name, String path, String source) {
    /* Core uses the current spelling; the frozen stage 1 sources use the old
     * one, where the lowercase literals are ordinary names. */
    bool legacy = legacy_syntax && !str_equal(name, STR("core"));
    return parse(name, path, lex(path, source, legacy));
}

static int read_file(const char *path, String *source) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return errno;
    }
    StringBuilder text = {0};
    char buf[8192];
    for (;;) {
        ssize_t len = read(fd, buf, sizeof(buf));
        if (len < 0) {
            int error = errno;
            if (error == EINTR) {
                continue;
            }
            close(fd);
            return error;
        }
        if (!len) {
            break;
        }
        sb_append(&text, (String){buf, (size_t)len});
    }
    close(fd);
    *source = sb_finish(&text);
    return 0;
}

static int write_file(const char *path, String text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) {
        return errno;
    }
    size_t at = 0;
    while (at < text.len) {
        ssize_t len = write(fd, text.data + at, text.len - at);
        if (len < 0) {
            int error = errno;
            if (error == EINTR) {
                continue;
            }
            close(fd);
            return error;
        }
        if (!len) {
            close(fd);
            /* A zero-byte write is a failure without an OS error. */
            return -1;
        }
        at += (size_t)len;
    }
    close(fd);
    return 0;
}

static String file_error(String path, int error) {
    String reason = error == -1 ? STR("failed to write whole buffer") : io_error(error);
    return str_format("willow0: %s: %s", path.data, reason.data);
}

/* Trim the separators and trailing current-directory components in Unix
 * paths, while retaining a leading root or current directory. */
static size_t path_end(String path, size_t end) {
    for (;;) {
        while (end > 1 && path.data[end - 1] == '/') {
            end--;
        }
        if (end >= 2 && path.data[end - 1] == '.' && path.data[end - 2] == '/') {
            end -= 2;
            if (!end) {
                return 1; /* /. */
            }
        } else {
            return end;
        }
    }
}

static String path_join(String root, String file) {
    if (!root.len) {
        return file;
    }
    return str_format("%s%s%s", root.data, root.data[root.len - 1] == '/' ? "" : "/", file.data);
}

/* The entry module, its imports in discovery order, and core last. */
static ModuleVec load_all(String root, String module_name, String path, String source) {
    ModuleVec modules = {0};
    vec_push(modules, load(module_name, path, source));
    Map seen = {0};
    map_insert(&seen, module_name, (void *)1);
    map_insert(&seen, STR("core"), (void *)1);
    size_t next = 0;
    while (next < modules.len) {
        ModuleVec found = {0};
        for (size_t i = 0; i < modules.data[next].imports.len; i++) {
            Import import = modules.data[next].imports.data[i];
            if (!map_insert(&seen, import.name, (void *)1)) {
                continue;
            }
            StringBuilder relative = {0};
            for (size_t j = 0; j < import.name.len; j++) {
                sb_push_byte(&relative, import.name.data[j] == '.' ? '/' : (unsigned char)import.name.data[j]);
            }
            sb_append(&relative, STR(".wlo"));
            String file = path_join(root, sb_finish(&relative));
            String imported;
            int error = read_file(file.data, &imported);
            if (!error) {
                vec_push(found, load(import.name, file, imported));
            } else if (error == ENOENT &&
                       (str_equal(import.name, STR("sys")) || str_equal(import.name, STR("fs")))) {
                continue;
            } else {
                String message = str_format("cannot load module '%s': %s: %s", import.name.data, file.data, strerror(error));
                fail(modules.data[next].path, import.pos, message);
            }
        }
        for (size_t i = 0; i < found.len; i++) {
            vec_push(modules, found.data[i]);
        }
        next++;
    }
    vec_push(modules, load(STR("core"), str_from_cstr(CORE_PATH), (String){CORE, sizeof(CORE) - 1}));
    return modules;
}

static bool alphabetic(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static String compile(String path) {
    String source;
    int error = read_file(path.data, &source);
    if (error) {
        fatal(file_error(path, error));
    }
    size_t end = path_end(path, path.len);
    size_t start = end;
    while (start && path.data[start - 1] != '/') {
        start--;
    }
    String stem = {path.data + start, end - start};
    if (str_equal(stem, STR(".")) || str_equal(stem, STR(".."))) {
        stem.len = 0;
    }
    for (size_t i = stem.len; i > 1; i--) {
        if (stem.data[i - 1] == '.') {
            stem.len = i - 1;
            break;
        }
    }
    String module_name = str_copy(stem.data, stem.len);
    bool valid = module_name.len && (alphabetic((unsigned char)module_name.data[0]) || module_name.data[0] == '_');
    for (size_t i = 0; i < module_name.len; i++) {
        unsigned char c = (unsigned char)module_name.data[i];
        if (!alphabetic(c) && !(c >= '0' && c <= '9') && c != '_') {
            valid = false;
        }
    }
    if (!valid || str_equal(module_name, STR("core"))) {
        fatal(str_format("willow0: %s: '%s' cannot be a module name", path.data, module_name.data));
    }
    size_t root_end = path_end(path, start);
    String root = str_copy(path.data, root_end);
    ModuleVec modules = load_all(root, module_name, path, source);
    Program program = check(modules);
    return emit(&program);
}

static const char *qbe_target(void) {
#if defined(__APPLE__) && defined(__aarch64__)
    return "arm64_apple";
#elif defined(__APPLE__) && defined(__x86_64__)
    return "amd64_apple";
#elif defined(__linux__) && defined(__aarch64__)
    return "arm64";
#elif defined(__linux__) && defined(__x86_64__)
    return "amd64_sysv";
#else
    struct utsname host;
    uname(&host);
#if defined(__APPLE__)
    const char *os = "macos";
#elif defined(__linux__)
    const char *os = "linux";
#else
    const char *os = host.sysname;
#endif
    fatal(str_format("willow0: unsupported host %s %s", os, host.machine));
#endif
}

static int wait_for(pid_t child, int *status) {
    while (waitpid(child, status, 0) < 0) {
        if (errno != EINTR) {
            return errno;
        }
    }
    return 0;
}

static String run(StringVec command) {
    char **args = xmalloc((command.len + 1) * sizeof(*args));
    for (size_t i = 0; i < command.len; i++) {
        if (memchr(command.data[i].data, '\0', command.data[i].len)) {
            return str_format("willow0: cannot run %s: nul byte found in provided data", command.data[0].data);
        }
        args[i] = (char *)command.data[i].data;
    }
    args[command.len] = NULL;
    pid_t child;
    int error = posix_spawnp(&child, args[0], NULL, NULL, args, environ);
    int status = 0;
    if (!error) {
        error = wait_for(child, &status);
    }
    if (error) {
        return str_format("willow0: cannot run %s: %s", args[0], io_error(error).data);
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        return str_format("willow0: %s failed", args[0]);
    }
    return STR("");
}

/* Replace each invalid UTF-8 sequence with U+FFFD. */
static String from_utf8_lossy(String bytes) {
    StringBuilder text = {0};
    size_t at = 0;
    while (at < bytes.len) {
        uint32_t c;
        if (utf8_decode(bytes, &at, &c)) {
            sb_push_char(&text, c);
            continue;
        }
        unsigned char first = (unsigned char)bytes.data[at++];
        size_t width = first >= 0xc2 && first <= 0xdf ? 2 :
            first >= 0xe0 && first <= 0xef ? 3 : first >= 0xf0 && first <= 0xf4 ? 4 : 1;
        for (size_t i = 1; i < width && at < bytes.len; i++) {
            unsigned char next = (unsigned char)bytes.data[at];
            if ((next & 0xc0) != 0x80 || (i == 1 &&
                ((first == 0xe0 && next < 0xa0) || (first == 0xed && next >= 0xa0) ||
                 (first == 0xf0 && next < 0x90) || (first == 0xf4 && next >= 0x90)))) {
                break;
            }
            at++;
        }
        sb_push_char(&text, 0xfffd);
    }
    return sb_finish(&text);
}

static bool whitespace(uint32_t c) {
    return (c >= 9 && c <= 13) || c == 0x20 || c == 0x85 || c == 0xa0 || c == 0x1680 ||
        (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f ||
        c == 0x205f || c == 0x3000;
}

/* Compiler flags that link libgc. Discard stderr and give the child null stdin. */
static StringVec gc_flags(void) {
    StringVec fallback = {0};
    vec_push(fallback, STR("-lgc"));
    int output[2];
    if (pipe(output) < 0) {
        return fallback;
    }
    posix_spawn_file_actions_t actions;
    int error = posix_spawn_file_actions_init(&actions);
    if (error) {
        close(output[0]);
        close(output[1]);
        return fallback;
    }
    error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!error) {
        error = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    }
    if (!error) {
        error = posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    }
    if (!error) {
        error = posix_spawn_file_actions_addclose(&actions, output[0]);
    }
    if (!error) {
        error = posix_spawn_file_actions_addclose(&actions, output[1]);
    }
    char *args[] = {"pkg-config", "--cflags", "--libs", "bdw-gc", NULL};
    pid_t child;
    if (!error) {
        error = posix_spawnp(&child, args[0], &actions, NULL, args, environ);
    }
    posix_spawn_file_actions_destroy(&actions);
    close(output[1]);
    if (error) {
        close(output[0]);
        return fallback;
    }
    StringBuilder captured = {0};
    char buf[8192];
    for (;;) {
        ssize_t len = read(output[0], buf, sizeof(buf));
        if (len < 0) {
            if (errno == EINTR) {
                continue;
            }
            error = errno;
            break;
        }
        if (!len) {
            break;
        }
        sb_append(&captured, (String){buf, (size_t)len});
    }
    close(output[0]);
    int status;
    int waited = wait_for(child, &status);
    if (error || waited || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        return fallback;
    }
    String text = from_utf8_lossy(sb_finish(&captured));
    StringVec flags = {0};
    size_t at = 0;
    size_t start = 0;
    while (at < text.len) {
        size_t before = at;
        uint32_t c;
        utf8_decode(text, &at, &c);
        if (whitespace(c)) {
            if (before > start) {
                vec_push(flags, str_copy(text.data + start, before - start));
            }
            start = at;
        }
    }
    if (at > start) {
        vec_push(flags, str_copy(text.data + start, at - start));
    }
    return flags;
}

static String temp_dir(void) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir) {
        return str_from_cstr(tmpdir);
    }
#if defined(__APPLE__)
    size_t len = confstr(_CS_DARWIN_USER_TEMP_DIR, NULL, 0);
    if (len) {
        char *dir = xmalloc(len);
        if (confstr(_CS_DARWIN_USER_TEMP_DIR, dir, len)) {
            return str_from_cstr(dir);
        }
    }
#endif
    return STR("/tmp");
}

static void remove_dir_all(String path) {
    struct stat info;
    if (lstat(path.data, &info) < 0) {
        return;
    }
    if (!S_ISDIR(info.st_mode)) {
        unlink(path.data);
        return;
    }
    DIR *dir = opendir(path.data);
    if (!dir) {
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) {
            remove_dir_all(path_join(path, str_from_cstr(entry->d_name)));
        }
    }
    closedir(dir);
    rmdir(path.data);
}

static String build(String il, String output) {
    const char *target = qbe_target();
    String dir = path_join(temp_dir(), str_format("willow0-%ld", (long)getpid()));
    if (mkdir(dir.data, 0777) < 0) {
        int error = errno;
        return file_error(dir, error);
    }
    String ssa = path_join(dir, STR("program.ssa"));
    String assembly = path_join(dir, STR("program.s"));
    String result = STR("");
    int error = write_file(ssa.data, il);
    if (error) {
        result = file_error(ssa, error);
    } else {
        StringVec command = {0};
        vec_push(command, STR("qbe"));
        vec_push(command, STR("-t"));
        vec_push(command, str_from_cstr(target));
        vec_push(command, STR("-o"));
        vec_push(command, assembly);
        vec_push(command, ssa);
        result = run(command);
        if (!result.len) {
            command = (StringVec){0};
            vec_push(command, STR("cc"));
            vec_push(command, STR("-o"));
            vec_push(command, output);
            vec_push(command, assembly);
            StringVec flags = gc_flags();
            for (size_t i = 0; i < flags.len; i++) {
                vec_push(command, flags.data[i]);
            }
            vec_push(command, STR("-lm"));
            result = run(command);
        }
    }
    remove_dir_all(dir);
    return result;
}

int main(int argc, char **argv) {
    int at = 1;
    if (at < argc && !strcmp(argv[at], "--legacy")) {
        legacy_syntax = true;
        at++;
    }
    if (argc - at != 4 || (strcmp(argv[at], "build") && strcmp(argv[at], "compile")) ||
        strcmp(argv[at + 2], "-o")) {
        fprintf(stderr, "%s\n", USAGE);
        return 2;
    }
    String il = compile(str_from_cstr(argv[at + 1]));
    String output = str_from_cstr(argv[at + 3]);
    String result = STR("");
    if (!strcmp(argv[at], "compile")) {
        int error = write_file(output.data, il);
        if (error) {
            result = file_error(output, error);
        }
    } else {
        result = build(il, output);
    }
    if (result.len) {
        fatal(result);
    }
    return 0;
}
