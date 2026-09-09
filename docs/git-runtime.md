# Git runtime

CSOS now has a reproducible build path for the upstream Git command-line
runtime. The source is kept outside the kernel tree in `.tools/git-src` and
the pinned Zig toolchain produces a statically linked x86_64 Linux/musl
binary at `zig-out/git-runtime/git`.

Build it with:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build-git-runtime.ps1
```

Pass the resulting image to the kernel build with
`-Dgit-runtime=zig-out/git-runtime/git`. The process loader maps the image
after the persistent FAT volume is mounted, provides `/dev/null`, and runs a
bounded `git --version` probe. The QEMU smoke test marker is
`CSOS Git runtime ready`.

The current milestone proves that the real upstream Git ELF can be loaded and
started inside CSOS. It does not yet claim full repository operations: the
userspace filesystem still needs complete working-directory and path
semantics, and HTTPS transport still needs the curl/OpenSSL dependency chain.
Those remain open before the Git update gate (`status`, `log`, `diff`,
`show`, `fetch`, `switch`, `reset`, and `pull`) can be marked complete.
