param(
    [string]$SourceDirectory = "$PSScriptRoot/../zig-out/pcre2-source/pcre2-10.44"
)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = (Resolve-Path $SourceDirectory).Path
$build = Join-Path $workspace 'zig-out/pcre2-linux'
$cmake = Join-Path $workspace '.tools/mesa-build-env/Scripts/cmake.exe'
$ninja = Join-Path $workspace '.tools/mesa-build-env/Scripts/ninja.exe'
$zig = Join-Path $workspace '.tools/zig-x86_64-windows-0.16.0/zig.exe'
$toolchain = Join-Path $workspace 'tools/zig-linux-toolchain.cmake'
$prefix = Join-Path $workspace 'zig-out/mesa-sysroot/usr'
& $cmake -S $source -B $build -G Ninja `
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain" "-DCMAKE_MAKE_PROGRAM=$ninja" `
    -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=OFF `
    -DPCRE2_BUILD_PCRE2_32=OFF -DPCRE2_BUILD_TESTS=OFF `
    -DPCRE2_SUPPORT_JIT=OFF -DPCRE2_SUPPORT_UNICODE=ON -DCMAKE_BUILD_TYPE=Release
if ($LASTEXITCODE -ne 0) { throw 'PCRE2 cross configuration failed.' }
& $ninja -C $build pcre2-8-static
if ($LASTEXITCODE -ne 0) { throw 'PCRE2 cross compilation failed.' }
$include = Join-Path $prefix 'include/pcre2'
$pkg = Join-Path $prefix 'lib/pkgconfig'
New-Item -ItemType Directory -Force -Path $include,$pkg | Out-Null
Copy-Item -Force (Join-Path $build 'pcre2.h') (Join-Path $include 'pcre2.h')
Copy-Item -Force (Join-Path $build 'libpcre2-8.a') (Join-Path $prefix 'lib/libpcre2-8.a')
$pc = @"
prefix=/usr
exec_prefix=`${prefix}
libdir=`${prefix}/lib
includedir=`${prefix}/include/pcre2

Name: libpcre2-8
Description: PCRE2 8-bit regular expression library
Version: 10.44
Libs: -L`${libdir} -lpcre2-8
Cflags: -I`${includedir}
"@
Set-Content -LiteralPath (Join-Path $pkg 'libpcre2-8.pc') -Value $pc -Encoding ascii
$magic = [IO.File]::ReadAllBytes((Join-Path $prefix 'lib/libpcre2-8.a'))
if ($magic.Length -lt 8) { throw 'PCRE2 static archive is empty.' }
Write-Output "PCRE2 10.44 staged for musl: $prefix"
