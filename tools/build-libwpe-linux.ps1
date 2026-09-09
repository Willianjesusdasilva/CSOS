$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = Join-Path $workspace '.tools/libwpe-src'
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne 'e0814ca7d4f87594a46732ebd309494872d2520e') {
    throw 'Expected libwpe 1.16.3 at the pinned commit.'
}
$meson = Join-Path $workspace '.tools/mesa-build-env/Scripts/meson.exe'
$ninja = Join-Path $workspace '.tools/mesa-build-env/Scripts/ninja.exe'
$env:PATH = "$(Join-Path $workspace '.tools/mesa-build-env/Scripts');$env:PATH"
$env:FORCE_PKGCONF_PYPI = '1'
$env:PKG_CONFIG_PATH = Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib/pkgconfig'
$env:PKG_CONFIG_LIBDIR = $env:PKG_CONFIG_PATH
$mesaHeaders = Join-Path $workspace '.tools/mesa-src/include'
$sysrootInclude = Join-Path $workspace 'zig-out/mesa-sysroot/usr/include'
New-Item -ItemType Directory -Force (Join-Path $sysrootInclude 'EGL') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $sysrootInclude 'KHR') | Out-Null
Copy-Item (Join-Path $mesaHeaders 'EGL/eglplatform.h') (Join-Path $sysrootInclude 'EGL/eglplatform.h') -Force
Copy-Item (Join-Path $mesaHeaders 'KHR/khrplatform.h') (Join-Path $sysrootInclude 'KHR/khrplatform.h') -Force
$buildDir = Join-Path $workspace 'zig-out/libwpe-linux'
$setupFlags = @()
if (Test-Path -LiteralPath "$buildDir/meson-private/coredata.dat") { $setupFlags += '--reconfigure' }
& $meson setup $buildDir $source @setupFlags --cross-file "$workspace/tools/glib-linux-cross.ini" `
    --default-library=static --buildtype=release --wrap-mode=nodownload `
    -Denable-xkb=false -Dbuild-docs=false
if ($LASTEXITCODE -ne 0) { throw 'libwpe cross configuration failed.' }
& $ninja -C $buildDir -j4
if ($LASTEXITCODE -ne 0) { throw 'libwpe compilation failed.' }
$include = Join-Path $workspace 'zig-out/mesa-sysroot/usr/include/wpe-1.0'
New-Item -ItemType Directory -Force $include | Out-Null
Copy-Item (Join-Path $source 'include/wpe') $include -Recurse -Force
Copy-Item (Join-Path $buildDir 'libwpe-1.0.a') (Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib/libwpe-1.0.a') -Force
$pc = @'
prefix=/usr
exec_prefix=${prefix}
libdir=${prefix}/lib
includedir=${prefix}/include/wpe-1.0

Name: wpe-1.0
Description: The WPE library
Version: 1.16.3
Libs: -L${libdir} -lwpe-1.0
Cflags: -I${includedir}
'@
Set-Content (Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib/pkgconfig/wpe-1.0.pc') $pc -NoNewline
Write-Output 'libwpe 1.16.3 built for the CSOS musl sysroot.'
