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
    & "$PSScriptRoot/configure-musl-runtime.ps1" -BuildDirectory $build
    if ($LASTEXITCODE -ne 0) { throw 'musl out-of-tree configuration failed.' }
}
$configPath = Join-Path $build 'config.mak'
$config = (Get-Content -LiteralPath $configPath -Raw).Replace('\', '/')
$expectedZig = $zig.Replace('\', '/')
$expectedWrapper = (Join-Path $workspace 'tools/zig-cc-wrapper.py').Replace('\', '/')
$requirements = @(
    @{ Pattern = '(?m)^ARCH = x86_64\s*$'; Error = 'musl config architecture is not x86_64.' },
    @{ Pattern = '(?m)^CFLAGS = .*\s-fPIC(?:\s|$)'; Error = 'musl config does not require PIC objects.' },
    @{ Pattern = '(?m)^CC = python ' + [regex]::Escape($expectedWrapper) + ' ' + [regex]::Escape($expectedZig) + ' cc -target x86_64-linux-musl\s*$'; Error = 'musl config does not use the pinned Zig target compiler.' },
    @{ Pattern = '(?m)^AR = ' + [regex]::Escape($expectedZig) + ' ar\s*$'; Error = 'musl config does not use the pinned Zig archiver.' },
    @{ Pattern = '(?m)^RANLIB = ' + [regex]::Escape($expectedZig) + ' ranlib\s*$'; Error = 'musl config does not use the pinned Zig ranlib.' },
    @{ Pattern = '(?m)^syslibdir = /usr/lib\s*$'; Error = 'musl config has the wrong runtime library directory.' }
)
foreach ($requirement in $requirements) {
    if ($config -notmatch $requirement.Pattern) { throw $requirement.Error }
}
$sourceMatch = [regex]::Match($config, '(?m)^srcdir = (.+?)\s*$')
if (-not $sourceMatch.Success) { throw 'musl config has no source directory.' }
$configuredSource = $sourceMatch.Groups[1].Value
if (-not [IO.Path]::IsPathRooted($configuredSource)) {
    $configuredSource = Join-Path $build $configuredSource
}
if ([IO.Path]::GetFullPath($configuredSource) -ne [IO.Path]::GetFullPath($source)) {
    throw 'musl config points at a different source checkout.'
}
& python "$PSScriptRoot/rebuild-musl-objects.py" $build
if ($LASTEXITCODE -ne 0) { throw 'musl object rebuild failed; staging preserved.' }
& python "$PSScriptRoot/link-musl-shared.py" $build $zig "$PSScriptRoot/zig-cc-wrapper.py"
if ($LASTEXITCODE -ne 0) { throw 'musl link/audit failed; staging preserved.' }
$runtime = Join-Path $build 'lib/libc.so'
New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
Copy-Item -LiteralPath $runtime -Destination $destination -Force
Write-Output "musl runtime: $destination"
