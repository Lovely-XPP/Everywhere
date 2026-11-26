// Launch the Qt bundle's Python protocol worker from the same directory after the app is moved.
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char path[PATH_MAX], resolved[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0 || !realpath(path, resolved)) return 1;
    char *base = strrchr(resolved, '/');
    if (!base || (size_t)(base - resolved) + sizeof("/EverywhereQt") > sizeof(resolved)) return 1;
    strcpy(base, "/EverywhereQt");
    char **args = calloc((size_t)argc + 2, sizeof(*args));
    if (!args) return 1;
    args[0] = resolved;
    args[1] = "--qt-worker";
    for (int i = 1; i < argc; ++i) args[i + 1] = argv[i];
    execv(resolved, args);
    perror("EverywhereQt");
    return 1;
}
