param(
    [string]$BuildDirectory = "$PSScriptRoot/../.tools/musl-build-pic"
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = Join-Path $workspace '.tools/musl-src'
$zig = Join-Path $workspace '.tools/zig-x86_64-windows-0.16.0/zig.exe'
$wrapper = Join-Path $workspace 'tools/zig-cc-wrapper.py'
$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path -LiteralPath $bash)) { throw 'Git for Windows bash is required to configure musl.' }
if (-not (Test-Path -LiteralPath (Join-Path $source 'configure'))) { throw 'Pinned musl source checkout is missing.' }
if (-not (Test-Path -LiteralPath $zig)) { throw 'Pinned Zig toolchain is missing.' }

$build = [IO.Path]::GetFullPath($BuildDirectory)
New-Item -ItemType Directory -Force -Path $build | Out-Null
$toPosix = { param([string]$path) $path.Replace('\', '/') }
$sourcePosix = & $toPosix $source
$buildPosix = & $toPosix $build
$oldCc = $env:CC
$oldCflags = $env:CFLAGS
$oldAr = $env:AR
$oldRanlib = $env:RANLIB
try {
    $env:CC = "python $(& $toPosix $wrapper) $(& $toPosix $zig) cc -target x86_64-linux-musl"
    $env:CFLAGS = '-O2 -fPIC'
    $env:AR = "$(& $toPosix $zig) ar"
    $env:RANLIB = "$(& $toPosix $zig) ranlib"
    & $bash -lc "cd '$buildPosix' && '$sourcePosix/configure' --prefix=/usr --syslibdir=/usr/lib --target=x86_64-linux-musl"
    if ($LASTEXITCODE -ne 0) { throw 'musl configure failed.' }
} finally {
    $env:CC = $oldCc
    $env:CFLAGS = $oldCflags
    $env:AR = $oldAr
    $env:RANLIB = $oldRanlib
}
if (-not (Test-Path -LiteralPath (Join-Path $build 'config.mak'))) { throw 'musl configure did not create config.mak.' }
Write-Output "musl build configured: $build"
