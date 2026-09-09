param([string]$SourceDirectory = "$PSScriptRoot/../zig-out/libffi-source")
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = (Resolve-Path $SourceDirectory).Path
$build = Join-Path $workspace 'zig-out/libffi-linux'
$meson = Join-Path $workspace '.tools/mesa-build-env/Scripts/meson.exe'
$ninja = Join-Path $workspace '.tools/mesa-build-env/Scripts/ninja.exe'
$prefix = Join-Path $workspace 'zig-out/mesa-sysroot/usr'
$env:PATH = "$(Split-Path $ninja);$env:PATH"
$env:NINJA = $ninja
& $meson setup $build $source --cross-file "$workspace/tools/glib-linux-cross.ini" --default-library=static --buildtype=release
if ($LASTEXITCODE -ne 0) { throw 'libffi cross configuration failed.' }
& $ninja -C $build
if ($LASTEXITCODE -ne 0) { throw 'libffi cross compilation failed.' }
$include = Join-Path $prefix 'include'
$lib = Join-Path $prefix 'lib'
$pkg = Join-Path $lib 'pkgconfig'
New-Item -ItemType Directory -Force -Path $include,$pkg | Out-Null
Copy-Item -Force "$build/include/ffi.h","$build/include/ffitarget.h" $include
Copy-Item -Force "$build/src/libffi.a" "$lib/libffi.a"
$pc = @"
prefix=/usr
exec_prefix=`${prefix}
libdir=`${prefix}/lib
includedir=`${prefix}/include

Name: libffi
Description: Foreign Function Interface library
Version: 3.2.9999
Libs: -L`${libdir} -lffi
Cflags: -I`${includedir}
"@
Set-Content -LiteralPath (Join-Path $pkg 'libffi.pc') -Value $pc -Encoding ascii
Write-Output "libffi staged for musl: $prefix"
