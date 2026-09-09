#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    int want_version = 0, want_cflags = 0, want_libs = 0, want_exists = 0;
    int is_boost = 0, is_blake = 0, is_archive = 0, is_crypto = 0, is_ssl = 0, is_openssl = 0, is_json = 0, is_curl = 0, is_sqlite = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--modversion")) want_version = 1;
        if (!strcmp(argv[i], "--cflags")) want_cflags = 1;
        if (!strcmp(argv[i], "--libs")) want_libs = 1;
        if (!strcmp(argv[i], "--version")) want_version = 2;
        if (!strcmp(argv[i], "--exists") || !strncmp(argv[i], "--atleast-version", 17)) want_exists = 1;
        if (!strcmp(argv[i], "boost")) is_boost = 1;
        if (!strcmp(argv[i], "libblake3")) is_blake = 1;
        if (!strcmp(argv[i], "libarchive")) is_archive = 1;
        if (!strcmp(argv[i], "libcrypto")) is_crypto = 1;
        if (!strcmp(argv[i], "libssl")) is_ssl = 1;
        if (!strcmp(argv[i], "openssl")) is_openssl = 1;
        if (!strcmp(argv[i], "nlohmann_json")) is_json = 1;
        if (!strcmp(argv[i], "libcurl") || !strcmp(argv[i], "curl")) is_curl = 1;
        if (!strcmp(argv[i], "sqlite3") || !strcmp(argv[i], "sqlite")) is_sqlite = 1;
    }
    if (want_version == 2) { puts("0.29.2"); return 0; }
    if (want_version == 1 && is_blake) { puts("1.8.2"); return 0; }
    if (want_version == 1 && is_boost) { puts("1.87.0"); return 0; }
    if (want_version == 1 && is_archive) { puts("3.8.7"); return 0; }
    if (want_version == 1 && (is_crypto || is_ssl || is_openssl)) { puts("3.5.8"); return 0; }
    if (want_version == 1 && is_json) { puts("3.11.3"); return 0; }
    if (want_version == 1 && is_curl) { puts("8.22.0"); return 0; }
    if (want_version == 1 && is_sqlite) { puts("3.53.4"); return 0; }
    if (want_exists) return 0;
    if (is_boost && want_cflags) { puts("-IC:/git/csos/zig-out/boost-tar2/boost_1_87_0"); return 0; }
    if (is_boost && want_libs) { puts("-LC:/git/csos/zig-out/boost-tar2/boost_1_87_0/stage/lib -lboost_context-mgw16-mt-x64-1_87 -lboost_coroutine-mgw16-mt-x64-1_87 -lboost_iostreams-mgw16-mt-x64-1_87 -lboost_system-mgw16-mt-x64-1_87"); return 0; }
    if (is_archive && want_cflags) { puts("-IC:/git/csos/zig-out/nix-sysroot-wsl/usr/include"); return 0; }
    if (is_archive && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -larchive"); return 0; }
    if ((is_crypto || is_ssl || is_openssl) && want_cflags) { puts("-IC:/git/csos/zig-out/nix-sysroot-wsl/usr/include"); return 0; }
    if (is_crypto && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lcrypto"); return 0; }
    if (is_ssl && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lssl -lcrypto"); return 0; }
    if (is_openssl && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lssl -lcrypto"); return 0; }
    if (is_json && want_cflags) { puts("-IC:/git/csos/zig-out/nix-sysroot-wsl/usr/include"); return 0; }
    if (is_json && want_libs) { puts(""); return 0; }
    if (is_curl && want_cflags) { puts("-IC:/git/csos/zig-out/nix-sysroot-wsl/usr/include"); return 0; }
    if (is_curl && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lcurl"); return 0; }
    if (is_sqlite && want_cflags) { puts("-IC:/git/csos/zig-out/nix-sysroot-wsl/usr/include"); return 0; }
    if (is_sqlite && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lsqlite3"); return 0; }
    if (want_cflags) { puts("-IC:/git/csos/zig-out/BLAKE3-1.8.2/c"); return 0; }
    if (want_libs) { puts("-LC:/git/csos/zig-out/blake3-lib -lblake3"); return 0; }
    return 0;
}
