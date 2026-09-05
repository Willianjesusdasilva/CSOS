param([ValidateRange(1, 64)][int]$Jobs = 4)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = Join-Path $workspace '.tools/mesa-src'
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne '9311c93dbef6b87a30bc282c3683efefc5f26f77') {
    throw 'The RADV build requires the pinned Mesa revision.'
}
$changes = & git -C $source status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Use an unmodified Mesa checkout.' }
$environmentScripts = Join-Path $workspace '.tools/mesa-build-env/Scripts'
$meson = Join-Path $environmentScripts 'meson.exe'
$build = Join-Path $workspace 'zig-out/mesa-radv'
if (-not (Test-Path -LiteralPath (Join-Path $build 'build.ninja'))) {
    throw 'Configure RADV with tools/configure-radv.ps1 first.'
}
$previousPath = $env:PATH
Push-Location $workspace
try {
    $env:PATH = "$environmentScripts;$previousPath"
    & $meson compile -C $build -j $Jobs
    if ($LASTEXITCODE -ne 0) { throw 'RADV compilation failed.' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workspace 'tools/audit-radv-elf.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'RADV ELF audit failed.' }
    $sourceLibrary = Join-Path $build 'src/amd/vulkan/libvulkan_radeon.so'
    $runtimeLibrary = Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib/libvulkan_radeon.so'
    $strip = (Get-Command strip.exe -ErrorAction Stop).Source
    & $strip --strip-all -o $runtimeLibrary $sourceLibrary
    if ($LASTEXITCODE -ne 0) { throw 'Failed to produce the stripped RADV runtime.' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workspace 'tools/audit-radv-elf.ps1') -Library $runtimeLibrary -Stripped
    if ($LASTEXITCODE -ne 0) { throw 'Stripped RADV runtime audit failed.' }
    if ((Get-Item -LiteralPath $runtimeLibrary).Length -gt 32 * 1024 * 1024) {
        throw 'Stripped RADV runtime exceeds the CSOS shared-object size limit.'
    }
} finally {
    $env:PATH = $previousPath
    Pop-Location
}
