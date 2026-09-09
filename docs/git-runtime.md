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
two-stage repository probe: `git init --bare /data/repo8` followed by
`git --git-dir=/data/repo8 rev-parse --is-bare-repository`. A second boot
reinitializes the same repository and reports persistence. The QEMU smoke test
marker is `CSOS Git runtime ready`.

The current milestone proves that the real upstream Git ELF can be loaded and
started inside CSOS and can create/reopen a persistent bare repository. Basic Linux filesystem ABI contracts used by Git now
include working-directory reporting, `chdir`, `rename`, `access`, and
`chmod`; a bounded `git init --bare` probe reached the repository config-lock
cycle before exposing the next FAT/VFS lock-file compatibility issue. Full
repository operations and the update gate (`status`, `log`, `diff`, `show`,
`fetch`, `switch`, `reset`, and `pull`) remain open. HTTPS transport also
still needs the curl/OpenSSL dependency chain.
