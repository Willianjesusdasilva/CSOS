param(
    [Parameter(Mandatory)][string]$SerialLog,
    [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$ExpectedDevice,
    [ValidatePattern('^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$')][string]$ExpectedBdf,
    [switch]$RequireDisplayEnumeration,
    [switch]$RequireDisplaySurface,
    [switch]$RequireDrmDisplayAcquisition,
    [switch]$RequireDisplaySwapchain,
    [switch]$RequireClearFramePresentation,
    [switch]$RequirePresentedTriangle,
    [switch]$AllowFixture
)

$ErrorActionPreference = 'Stop'
$logPath = (Resolve-Path -LiteralPath $SerialLog).Path
$log = Get-Content -LiteralPath $logPath -Raw
if (-not $AllowFixture -and $log.Contains('TEST FIXTURE')) {
    throw 'Test fixtures cannot be used as physical hardware evidence.'
}

$identity = [regex]::Match($log, 'GPU PCI vendor: (\d+) device: (\d+)')
if (-not $identity.Success) { throw 'Serial log has no GPU PCI identity.' }
$vendor = [int]$identity.Groups[1].Value
$device = [int]$identity.Groups[2].Value
if ($vendor -ne 0x1002) { throw "Serial log is not from an AMD GPU (vendor=$vendor)." }
if ($device -ne $ExpectedDevice) { throw "GPU PCI device mismatch: expected $ExpectedDevice, observed $device." }

$bdfMatch = [regex]::Match($log, 'RADV matched PCI BDF: ([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7])')
if (-not $bdfMatch.Success) { throw 'Serial log has no matched DRM/Vulkan PCI BDF.' }
$matchedBdf = $bdfMatch.Groups[1].Value.ToLowerInvariant()
if ($ExpectedBdf -and $matchedBdf -ne $ExpectedBdf.ToLowerInvariant()) {
    throw "GPU PCI BDF mismatch: expected $ExpectedBdf, observed $matchedBdf."
}

$vulkan = [regex]::Match($log, 'RADV V device count: 0x([0-9a-fA-F]{8})')
if (-not $vulkan.Success) { throw 'Serial log has no Vulkan physical-device count.' }
$deviceCount = [Convert]::ToUInt32($vulkan.Groups[1].Value, 16)
if ($deviceCount -eq 0) { throw 'RADV did not enumerate a physical Vulkan device.' }

$required = @(
    'RADV direct display instance extensions ready',
    'RADV DRM KMS primary plane ready',
    'RADV Vulkan device matches DRM PCI identity',
    'RADV logical device and graphics queue ready',
    'RADV triangle shader modules ready',
    'RADV triangle graphics pipeline ready',
    'RADV triangle offscreen framebuffer ready',
    'RADV triangle readback buffer ready',
    'RADV offscreen triangle draw ready',
    'RADV offscreen triangle pixels verified',
    'RADV command submission and fence ready'
)
foreach ($marker in $required) {
    if (-not $log.Contains($marker)) { throw "Missing physical RADV gate: $marker" }
}
if ($RequireDisplayEnumeration -and
    -not $log.Contains('RADV direct display modes and planes ready')) {
    throw 'No physical Vulkan display/mode/plane enumeration evidence.'
}
if ($RequireDisplaySurface -and
    -not $log.Contains('RADV direct display surface ready')) {
    throw 'No physical Vulkan display-plane surface evidence.'
}
if ($RequireDrmDisplayAcquisition) {
    foreach ($marker in @('RADV connected DRM KMS connector ready', 'RADV DRM display acquired')) {
        if (-not $log.Contains($marker)) { throw "Missing DRM display acquisition gate: $marker" }
    }
}
if ($RequireDisplaySwapchain -and
    -not $log.Contains('RADV direct display swapchain ready')) {
    throw 'No physical direct-display Vulkan swapchain evidence.'
}
if ($RequireClearFramePresentation -and
    -not $log.Contains('RADV direct display clear frame presented')) {
    throw 'No synchronized direct-display clear-frame presentation evidence.'
}
if ($RequirePresentedTriangle -and
    -not $log.Contains('RADV direct display triangle presented')) {
    throw 'No synchronized direct-display triangle presentation evidence.'
}

$blueMatch = [regex]::Match($log, 'RADV B device count: 0x([0-9a-fA-F]{8})')
$blackMatch = [regex]::Match($log, 'RADV K device count: 0x([0-9a-fA-F]{8})')
if (-not $blueMatch.Success -or -not $blackMatch.Success) {
    throw 'Serial log has no full-frame triangle pixel counts.'
}
$blue = [Convert]::ToUInt32($blueMatch.Groups[1].Value, 16)
$black = [Convert]::ToUInt32($blackMatch.Groups[1].Value, 16)
if ($blue -lt 680 -or $blue -gt 760 -or $black -lt 3300 -or
    $blue + $black -lt 4080 -or $blue + $black -gt 4096) {
    throw "Offscreen triangle coverage is invalid: blue=$blue black=$black."
}

if ($AllowFixture) {
    Write-Output "RADV hardware-log fixture contract verified for AMD PCI 1002:$('{0:x4}' -f $device) at $matchedBdf."
} else {
    Write-Output "RADV offscreen triangle pixels verified on AMD PCI 1002:$('{0:x4}' -f $device) at $matchedBdf; display presentation remains a separate gate."
}
