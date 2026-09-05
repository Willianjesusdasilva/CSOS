$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$sourceRoot = Join-Path $workspace '.tools/llvm-project-21.1.0'
$expectedRevision = '3623fe661ae35c6c80ac221f14d85be76aa870f1'
$revision = & git -C $sourceRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne $expectedRevision) {
    throw "The compiler-rt CPU runtime requires llvm-project revision $expectedRevision."
}
$changes = & git -C $sourceRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Use an unmodified llvm-project checkout.' }

$zig = Join-Path $workspace '.tools/zig-x86_64-windows-0.16.0/zig.exe'
$builtins = Join-Path $sourceRoot 'compiler-rt/lib/builtins'
$source = Join-Path $builtins 'cpu_model/x86.c'
$destination = Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib/compiler-rt-cpu-model.o'
if (-not (Test-Path -LiteralPath $source)) {
    throw 'Missing compiler-rt/lib/builtins/cpu_model/x86.c; prepare the pinned sparse checkout first.'
}
New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
& $zig cc -target x86_64-linux-musl -O2 -fPIC -I $builtins -c $source -o $destination
if ($LASTEXITCODE -ne 0) { throw 'Failed to build the compiler-rt x86 CPU model runtime.' }

$header = [System.IO.File]::ReadAllBytes($destination)[0..3]
if ($header[0] -ne 0x7f -or $header[1] -ne 0x45 -or $header[2] -ne 0x4c -or $header[3] -ne 0x46) {
    throw 'The compiler-rt CPU model output is not ELF.'
}
Write-Output "compiler-rt CPU model: $destination"
