$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$zig = Join-Path $workspace '.tools/zig-x86_64-windows-0.16.0/zig.exe'
$destination = Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib/libc.so'
$source = Join-Path $workspace '.tools/musl-src'
$build = Join-Path $workspace '.tools/musl-build-pic'
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne '0784374d561435f7c787a555aeab8ede699ed298') {
    throw 'Expected the pinned upstream musl v1.2.5 checkout.'
}
$changes = & git -C $source status --porcelain
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'musl source checkout must be clean.' }
if (-not (Test-Path -LiteralPath (Join-Path $build 'config.mak'))) {
    throw 'Configure the out-of-tree musl-build-pic directory with Zig x86_64-linux-musl and -O2 -fPIC first.'
}
& python "$PSScriptRoot/rebuild-musl-objects.py" $build
if ($LASTEXITCODE -ne 0) { throw 'musl object rebuild failed; staging preserved.' }
& python "$PSScriptRoot/link-musl-shared.py" $build $zig "$PSScriptRoot/zig-cc-wrapper.py"
if ($LASTEXITCODE -ne 0) { throw 'musl link/audit failed; staging preserved.' }
$runtime = Join-Path $build 'lib/libc.so'
New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
Copy-Item -LiteralPath $runtime -Destination $destination -Force
Write-Output "musl runtime: $destination"
