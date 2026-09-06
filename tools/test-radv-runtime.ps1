param(
    [ValidateRange(1, 300)][int]$SmokeTestSeconds = 30,
    [string]$Runtime = "$PSScriptRoot/../zig-out/mesa-sysroot/usr/lib/libvulkan_radeon.so"
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$zig = Join-Path $workspace '.tools/zig-x86_64-windows-0.16.0/zig.exe'
$probe = Join-Path $workspace 'zig-out/radv-loader-probe'
$runtimePath = (Resolve-Path -LiteralPath $Runtime).Path
$runtimeBuildPath = [IO.Path]::GetRelativePath($workspace, $runtimePath).Replace('\', '/')
$probeBuildPath = [IO.Path]::GetRelativePath($workspace, $probe).Replace('\', '/')
$initialQemu = @(Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | ForEach-Object Id)

Push-Location $workspace
try {
    & "$PSScriptRoot/build-radv-loader-probe.ps1"
    if ($LASTEXITCODE -ne 0) { throw 'RADV loader probe build failed.' }
    & $zig build run "-Dradv-runtime=$runtimeBuildPath" "-Dradv-loader-probe=$probeBuildPath" `
        '-Dradv-probe-after-gpu=true' -- -ResetDisk `
        -SmokeTestSeconds $SmokeTestSeconds -ExpectSerial 'RADV dynamic loader ready'
    if ($LASTEXITCODE -ne 0) { throw 'RADV runtime boot did not reach its final gate.' }
    Write-Output 'RADV runtime, complete libdrm discovery, Vulkan instance and bounded boot passed; physical GPU remains unverified.'
} finally {
    Pop-Location
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -notin $initialQemu } |
        Stop-Process -Force
}
