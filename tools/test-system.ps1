param(
    [ValidateRange(1, 300)][int]$SmokeTestSeconds = 30,
    [string]$LibdrmSource = "$PSScriptRoot/../.tools/libdrm-src"
)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$zig = Join-Path $workspace '.tools/zig-x86_64-windows-0.16.0/zig.exe'
if (-not (Test-Path -LiteralPath $zig)) { throw 'The pinned Zig toolchain is missing.' }
if (-not (Test-Path -LiteralPath $LibdrmSource)) {
    throw 'Supply -LibdrmSource pointing to the pinned upstream libdrm checkout; see docs/radv-bringup-audit.md.'
}
Push-Location $workspace
try {
    & $zig build test --summary all
    if ($LASTEXITCODE -ne 0) { throw 'CSOS host tests failed.' }
    & "$PSScriptRoot/build-libdrm-probe.ps1" -SourceDirectory $LibdrmSource
    if ($LASTEXITCODE -ne 0) { throw 'Upstream libdrm probe build failed.' }
    & $zig build run -- -SmokeTestSeconds $SmokeTestSeconds -ExpectSerial 'CSOS console shell ready'
    if ($LASTEXITCODE -ne 0) { throw 'Normal boot did not reach the console.' }
    & $zig build run -Ddrm-amdgpu-abi-test=true `
        -Dlibdrm-probe=zig-out/libdrm-probe/libdrm-probe -Dlibdrm-probe-after-gpu=true `
        -- -SmokeTestSeconds $SmokeTestSeconds -ExpectSerial 'CSOS console shell ready'
    if ($LASTEXITCODE -ne 0) { throw 'Combined AMDGPU ABI and upstream libdrm boot failed.' }
    Write-Output 'CSOS host tests and both bounded console boots passed; physical Vulkan remains unverified.'
} finally {
    Pop-Location
}
