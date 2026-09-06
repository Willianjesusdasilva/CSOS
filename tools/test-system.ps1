param(
    [ValidateRange(1, 300)][int]$SmokeTestSeconds = 30,
    [string]$LibdrmSource = "$PSScriptRoot/../.tools/libdrm-src"
)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$zig = Join-Path $workspace '.tools/zig-x86_64-windows-0.16.0/zig.exe'
$qemuBefore = @(Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | ForEach-Object Id)
if (-not (Test-Path -LiteralPath $zig)) { throw 'The pinned Zig toolchain is missing.' }
if (-not (Test-Path -LiteralPath $LibdrmSource)) {
    throw 'Supply -LibdrmSource pointing to the pinned upstream libdrm checkout; see docs/radv-bringup-audit.md.'
}
Push-Location $workspace
try {
    & $zig build test --summary all
    if ($LASTEXITCODE -ne 0) { throw 'CSOS host tests failed.' }
    & "$PSScriptRoot/verify-radv-hardware-log.ps1" `
        -SerialLog "$workspace/tests/data/radv-hardware-log.fixture" `
        -ExpectedDevice 29772 -AllowFixture
    if ($LASTEXITCODE -ne 0) { throw 'RADV hardware-log verifier fixture failed.' }
    & "$PSScriptRoot/build-libdrm-probe.ps1" -SourceDirectory $LibdrmSource
    if ($LASTEXITCODE -ne 0) { throw 'Upstream libdrm probe build failed.' }
    & $zig build run -- -SmokeTestSeconds $SmokeTestSeconds -ExpectSerial 'CSOS graphical session ready'
    if ($LASTEXITCODE -ne 0) { throw 'Normal boot did not reach the graphical session.' }
    & $zig build run -Ddrm-amdgpu-abi-test=true `
        -Dlibdrm-probe=zig-out/libdrm-probe/libdrm-probe -Dlibdrm-probe-after-gpu=true `
        -- -SmokeTestSeconds $SmokeTestSeconds -ExpectSerial 'CSOS graphical session ready'
    if ($LASTEXITCODE -ne 0) { throw 'Combined AMDGPU ABI and upstream libdrm boot failed.' }
    Write-Output 'CSOS host tests and both bounded graphical boots passed; physical Vulkan remains unverified.'
} finally {
    # Remove only emulator processes created by this test run. This keeps the
    # user's unrelated QEMU sessions untouched while preventing test leaks.
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
        Where-Object { $qemuBefore -notcontains $_.Id } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Pop-Location
}
