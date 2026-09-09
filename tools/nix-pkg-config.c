#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    int want_version = 0, want_cflags = 0, want_libs = 0, want_exists = 0;
    int is_boost = 0, is_blake = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--modversion")) want_version = 1;
        if (!strcmp(argv[i], "--cflags")) want_cflags = 1;
        if (!strcmp(argv[i], "--libs")) want_libs = 1;
        if (!strcmp(argv[i], "--version")) want_version = 2;
        if (!strcmp(argv[i], "--exists") || !strncmp(argv[i], "--atleast-version", 17)) want_exists = 1;
        if (!strcmp(argv[i], "boost")) is_boost = 1;
        if (!strcmp(argv[i], "libblake3")) is_blake = 1;
    }
    if (want_version == 2) { puts("0.29.2"); return 0; }
    if (want_version == 1 && is_blake) { puts("1.8.2"); return 0; }
    if (want_version == 1 && is_boost) { puts("1.87.0"); return 0; }
    if (want_exists) return 0;
    if (is_boost && want_cflags) { puts("-IC:/git/csos/zig-out/boost-tar2/boost_1_87_0"); return 0; }
    if (is_boost && want_libs) { puts("-LC:/git/csos/zig-out/boost-tar2/boost_1_87_0/stage/lib -lboost_context-mgw16-mt-x64-1_87 -lboost_coroutine-mgw16-mt-x64-1_87 -lboost_iostreams-mgw16-mt-x64-1_87 -lboost_system-mgw16-mt-x64-1_87"); return 0; }
    if (want_cflags) { puts("-IC:/git/csos/zig-out/BLAKE3-1.8.2/c"); return 0; }
    if (want_libs) { puts("-LC:/git/csos/zig-out/blake3-lib -lblake3"); return 0; }
    return 0;
}
