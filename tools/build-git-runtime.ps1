param(
    [string]$SourceDirectory = "$PSScriptRoot/../.tools/git-src",
    [string]$OutputDirectory = "$PSScriptRoot/../zig-out/git-runtime"
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = [IO.Path]::GetFullPath($SourceDirectory)
$output = [IO.Path]::GetFullPath($OutputDirectory)
$bash = 'C:\Program Files\Git\bin\bash.exe'
$zig = "$workspace/.tools/zig-x86_64-windows-0.16.0/zig.exe"
if (-not (Test-Path -LiteralPath $bash)) { throw 'Git for Windows bash is required to build the upstream Git runtime.' }
if (-not (Test-Path -LiteralPath $zig)) { throw 'The pinned Zig toolchain is missing.' }
if (-not (Test-Path -LiteralPath "$source/Makefile")) { throw 'Fetch the pinned Git source into .tools/git-src first.' }

New-Item -ItemType Directory -Force -Path $output | Out-Null
$sourceUnix = (& $bash -lc "cygpath -u '$source'").Trim()
$zigUnix = (& $bash -lc "cygpath -u '$zig'").Trim()
$sysrootUnix = (& $bash -lc "cygpath -u '$workspace/zig-out/mesa-sysroot/usr'").Trim()
$outputUnix = (& $bash -lc "cygpath -u '$output'").Trim()
$command = @"
set -eu
cd '$sourceUnix'
make clean >/dev/null 2>&1 || true
rm -f GIT-CFLAGS GIT-LDFLAGS config.mak.autogen
make -j4 git uname_S=Linux uname_M=x86_64 uname_O=GNU prefix=/usr FALLBACK_RUNTIME_PREFIX=/usr \
  CC='$zigUnix cc -target x86_64-linux-musl' \
  AR='$zigUnix ar' NO_CURL=YesPlease NO_OPENSSL=YesPlease NO_GETTEXT=YesPlease \
  NO_TCLTK=YesPlease NO_PERL=YesPlease NO_PYTHON=YesPlease NO_INSTALL_HARDLINKS=YesPlease \
  NO_REGEX=NeedsStartEnd CFLAGS='-O2 -I$sysrootUnix/include' \
  LDFLAGS='-static -L$sysrootUnix/lib'
cp git '$outputUnix/git'
"@
& $bash -lc $command
if ($LASTEXITCODE -ne 0) { throw 'Upstream Git runtime build failed.' }
Write-Output "Built upstream Git runtime: $output/git"
