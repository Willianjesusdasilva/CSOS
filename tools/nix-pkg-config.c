#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    int target_musl = getenv("CSOS_NIX_TARGET") != NULL;
    int want_version = 0, want_cflags = 0, want_libs = 0, want_exists = 0, want_libdir = 0, want_print_variables = 0;
    int is_boost = 0, is_blake = 0, is_archive = 0, is_crypto = 0, is_ssl = 0, is_openssl = 0, is_json = 0, is_curl = 0, is_sqlite = 0, is_git2 = 0, is_edit = 0, is_toml = 0, is_sodium = 0, is_brotli_common = 0, is_brotli_dec = 0, is_brotli_enc = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--modversion")) want_version = 1;
        if (!strcmp(argv[i], "--cflags")) want_cflags = 1;
        if (!strcmp(argv[i], "--libs")) want_libs = 1;
        if (!strcmp(argv[i], "--variable=libdir")) want_libdir = 1;
        if (!strcmp(argv[i], "--print-variables")) want_print_variables = 1;
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
        if (!strcmp(argv[i], "libgit2")) is_git2 = 1;
        if (!strcmp(argv[i], "libeditline") || !strcmp(argv[i], "editline") || !strcmp(argv[i], "libedit")) is_edit = 1;
        if (!strcmp(argv[i], "toml11")) is_toml = 1;
        if (!strcmp(argv[i], "libsodium") || !strcmp(argv[i], "sodium")) is_sodium = 1;
        if (!strcmp(argv[i], "libbrotlicommon")) is_brotli_common = 1;
        if (!strcmp(argv[i], "libbrotlidec")) is_brotli_dec = 1;
        if (!strcmp(argv[i], "libbrotlienc")) is_brotli_enc = 1;
    }
    if (want_version == 2) { puts("0.29.2"); return 0; }
    if (want_version == 1 && is_blake) { puts("1.8.2"); return 0; }
    if (want_version == 1 && is_boost) { puts("1.87.0"); return 0; }
    if (want_version == 1 && is_archive) { puts("3.8.7"); return 0; }
    if (want_version == 1 && (is_crypto || is_ssl || is_openssl)) { puts("3.5.8"); return 0; }
    if (want_version == 1 && is_json) { puts("3.11.3"); return 0; }
    if (want_version == 1 && is_curl) { puts("8.22.0"); return 0; }
    if (want_version == 1 && is_sqlite) { puts("3.53.4"); return 0; }
    if (want_version == 1 && is_git2) { puts("1.9.0"); return 0; }
    if (want_version == 1 && is_edit) { puts("3.1"); return 0; }
    if (want_version == 1 && is_toml) { puts("4.4.0"); return 0; }
    if (want_exists) return 0;
    if (is_boost && want_libdir) {
        if (target_musl) puts("C:/git/csos/zig-out/nix-sysroot-wsl/usr/lib");
        else puts("C:/git/csos/zig-out/boost-tar2/boost_1_87_0/stage/lib");
        return 0;
    }
    if (is_boost && want_print_variables) { puts("libdir\nincludedir\nprefix"); return 0; }
    if (is_boost && !strcmp(argv[1], "--variable=includedir")) { puts("C:/git/csos/zig-out/boost-tar2/boost_1_87_0"); return 0; }
    if (is_boost && !strcmp(argv[1], "--variable=prefix")) { puts("C:/git/csos/zig-out/boost-tar2/boost_1_87_0"); return 0; }
    if (is_boost && want_cflags) { puts("-IC:/git/csos/zig-out/boost-tar2/boost_1_87_0"); return 0; }
    if (is_boost && want_libs) {
        if (target_musl) puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lboost_context -lboost_coroutine -lboost_iostreams -lboost_system -lboost_url");
        else puts("-LC:/git/csos/zig-out/boost-tar2/boost_1_87_0/stage/lib -lboost_context-mgw16-mt-x64-1_87 -lboost_coroutine-mgw16-mt-x64-1_87 -lboost_iostreams-mgw16-mt-x64-1_87 -lboost_system-mgw16-mt-x64-1_87");
        return 0;
    }
    if (is_blake && want_cflags) { puts("-IC:/git/csos/zig-out/BLAKE3-1.8.2/c"); return 0; }
    if (is_blake && want_libs) {
        if (target_musl) puts("-LC:/git/csos/zig-out/blake3-musl -lblake3");
        else puts("-LC:/git/csos/zig-out/blake3-lib -lblake3");
        return 0;
    }
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
    if (is_git2 && want_cflags) { puts("-IC:/git/csos/zig-out/nix-sysroot-wsl/usr/include"); return 0; }
    if (is_git2 && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lgit2"); return 0; }
    if (is_edit && want_cflags) { puts("-IC:/git/csos/zig-out/nix-sysroot-wsl/usr/include -IC:/git/csos/zig-out/nix-sysroot-wsl/usr/include/editline"); return 0; }
    if (is_edit && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -leditline"); return 0; }
    if (is_toml && want_cflags) { puts("-IC:/git/csos/zig-out/nix-sysroot-wsl/usr/include"); return 0; }
    if (is_toml && want_libs) { puts(""); return 0; }
    if (is_sodium && want_cflags) { puts("-IC:/git/csos/zig-out/nix-sysroot-wsl/usr/include"); return 0; }
    if (is_sodium && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lsodium"); return 0; }
    if (is_brotli_common && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lbrotlicommon"); return 0; }
    if (is_brotli_dec && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lbrotlidec"); return 0; }
    if (is_brotli_enc && want_libs) { puts("-LC:/git/csos/zig-out/nix-sysroot-wsl/usr/lib -lbrotlienc"); return 0; }
    if (want_cflags) { puts("-IC:/git/csos/zig-out/BLAKE3-1.8.2/c"); return 0; }
    if (want_libs) { puts("-LC:/git/csos/zig-out/blake3-musl -lblake3"); return 0; }
    return 0;
}
