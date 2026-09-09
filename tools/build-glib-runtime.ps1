$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = Join-Path $workspace '.tools/glib-src'
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne '41eca60845d3fc309af361f5e7f801ba339099aa') {
    throw 'Expected upstream GLib 2.84.4 at the pinned commit.'
}
$changes = & git -C $source status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'GLib tracked sources must be clean.' }
$meson = Join-Path $workspace '.tools/mesa-build-env/Scripts/meson.exe'
$buildDir = Join-Path $workspace 'zig-out/glib-linux'
# pkgconf-pypi intentionally ignores host search paths unless explicitly forced.
# Keep dependency discovery deterministic for the staged musl sysroot.
$env:FORCE_PKGCONF_PYPI = '1'
$env:PKG_CONFIG_PATH = Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib/pkgconfig'
$env:PKG_CONFIG_LIBDIR = $env:PKG_CONFIG_PATH
$setupFlags = @()
if (Test-Path -LiteralPath "$buildDir/meson-private/coredata.dat") { $setupFlags += '--reconfigure' }
& $meson setup $buildDir $source @setupFlags --cross-file "$workspace/tools/glib-linux-cross.ini" `
    --default-library=static --buildtype=release --wrap-mode=nodownload -Dtests=false -Dinstalled_tests=false `
    -Ddocumentation=false -Dintrospection=disabled -Dlibmount=disabled -Dselinux=disabled `
    -Dsysprof=disabled -Dnls=disabled -Dglib_debug=disabled -Dbsymbolic_functions=false `
    -Dforce_posix_threads=true
if ($LASTEXITCODE -ne 0) { throw 'GLib cross configuration failed.' }
& "$workspace/.tools/mesa-build-env/Scripts/ninja.exe" -C $buildDir -j4 glib/libglib-2.0.a glib/libcharset/libcharset.a
if ($LASTEXITCODE -ne 0) { throw 'Upstream GLib compilation failed.' }
$supportLibraries = @("$buildDir/glib/libcharset/libcharset.a")
if (Test-Path -LiteralPath "$buildDir/glib/gnulib/libgnulib.a") {
    $supportLibraries += "$buildDir/glib/gnulib/libgnulib.a"
}
$supportLibraries += @(
    "$workspace/zig-out/mesa-sysroot/usr/lib/libpcre2-8.a",
    "$workspace/zig-out/mesa-sysroot/usr/lib/libffi.a"
)
& "$workspace/.tools/zig-x86_64-windows-0.16.0/zig.exe" build-exe `
    "$workspace/userspace/glib_runtime_probe.zig" "$buildDir/glib/libglib-2.0.a" `
    @supportLibraries `
    -target x86_64-linux-musl -O ReleaseSmall -lc -lm -static `
    "-femit-bin=$workspace/zig-out/glib-runtime-probe"
if ($LASTEXITCODE -ne 0) { throw 'Upstream GLib probe link failed.' }
Write-Output 'GLib probe built; only a CSOS/QEMU run can validate runtime.'
