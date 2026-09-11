param(
    [string]$Source = "$PSScriptRoot/../.tools/wpebackend-fdo-src",
    [string]$Build = "$PSScriptRoot/../zig-out/wpebackend-fdo-linux",
    [switch]$Stage
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
$zig = Join-Path $root '.tools/zig-x86_64-windows-0.16.0/zig.exe'
$meson = Join-Path $root '.tools/mesa-build-env/Scripts/meson.exe'
$ninja = Join-Path $root '.tools/mesa-build-env/Scripts/ninja.exe'
$sysroot = Join-Path $root 'zig-out/mesa-sysroot'
$cross = Join-Path $root 'tools/glib-linux-cross.ini'
$native = Join-Path $root 'tools/wayland-native.ini'

if (-not (Test-Path $Source)) { throw "WPE backend source not found: $Source" }
if (-not (Test-Path $sysroot)) { throw "Target sysroot not found: $sysroot" }

$env:PKG_CONFIG_LIBDIR = (Join-Path $sysroot 'usr/lib/pkgconfig')
$env:PKG_CONFIG_SYSROOT_DIR = $sysroot
$env:PKG_CONFIG_PATH = (Join-Path $root '.tools/wayland-scanner-native/pkgconfig')

$include = Join-Path $sysroot 'usr/include'
$flags = "-I$include -I$include/glib-2.0 -I$include/pcre2 -I$include/wpe-1.0 -include unistd.h -fPIC -fno-sanitize=undefined"

& $meson setup $Source $Build --wipe --cross-file $cross --native-file $native --buildtype release --default-library static -Dbuild_docs=false -Dc_args=$flags -Dcpp_args=$flags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $ninja -C $Build -j4
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$artifact = Join-Path $Build 'libWPEBackend-fdo-1.0.so.1.10.2'
if (-not (Test-Path $artifact)) { throw "WPE backend artifact was not produced: $artifact" }
Write-Host "Built $artifact"

if ($Stage) {
    $libdir = Join-Path $sysroot 'usr/lib'
    Copy-Item $artifact (Join-Path $libdir 'libWPEBackend-fdo-1.0.so.1.10.2') -Force
    Copy-Item (Join-Path $Build 'meson-private/wpebackend-fdo-1.0.pc') (Join-Path $libdir 'pkgconfig/wpebackend-fdo-1.0.pc') -Force
    Write-Host "Staged WPE backend into $libdir"
}
