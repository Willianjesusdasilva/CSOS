$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$zig = Join-Path $workspace '.tools/zig-x86_64-windows-0.16.0/zig.exe'
$sysrootLib = Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib'
$source = Join-Path $workspace 'userspace/radv_loader_probe.c'
$output = Join-Path $workspace 'zig-out/radv-loader-probe'
$radv = Join-Path $sysrootLib 'libvulkan_radeon.so'
if (-not (Test-Path -LiteralPath $radv)) { throw 'Build the stripped RADV runtime first.' }
& "$PSScriptRoot/build-radv-shaders.ps1"
if ($LASTEXITCODE -ne 0) { throw 'RADV triangle shader build failed.' }
& $zig cc -target x86_64-linux-musl -O2 -fPIE -pie -nostdlib -Wno-shift-op-parentheses `
    '-Wl,--dynamic-linker=/lib/ld-csos.so' '-Wl,--no-as-needed' `
    "-I$workspace/.tools/musl-build-pic/obj/include" `
    "-I$workspace/.tools/musl-src/arch/x86_64" "-I$workspace/.tools/musl-src/include" `
    "-I$workspace/.tools/zig-x86_64-windows-0.16.0/lib/libc/include/any-linux-any" `
    "-I$workspace/.tools/mesa-src/include" "-I$workspace/.tools/libdrm-src" `
    "-I$workspace/.tools/libdrm-src/include/drm" `
    "-I$workspace/zig-out/radv-shaders" `
    $source $radv "$sysrootLib/libdrm.so.2" -o $output
if ($LASTEXITCODE -ne 0) { throw 'Failed to build RADV loader probe.' }
$readelf = (Get-Command readelf.exe -ErrorAction Stop).Source
$strings = (Get-Command strings.exe -ErrorAction Stop).Source
$dynamic = (& $readelf -dW $output) -join "`n"
$programs = (& $readelf -lW $output) -join "`n"
if ($dynamic -notmatch '\(NEEDED\).*\[libvulkan_radeon\.so\]' -or
    $dynamic -notmatch '\(NEEDED\).*\[libdrm\.so\.2\]' -or
    $programs -notmatch 'Requesting program interpreter:\s*/lib/ld-csos\.so') {
    throw 'RADV loader probe lacks its required CSOS dynamic-link contract.'
}
$messages = (& $strings $output) -join "`n"
if ($messages -notmatch 'RADV logical device and graphics queue ready' -or
    $messages -notmatch 'RADV direct display instance extensions ready' -or
    $messages -notmatch 'RADV direct display modes and planes ready' -or
    $messages -notmatch 'RADV connected DRM KMS connector ready' -or
    $messages -notmatch 'RADV DRM KMS primary plane ready' -or
    $messages -notmatch 'RADV DRM display acquired' -or
    $messages -notmatch 'RADV Vulkan device matches DRM PCI identity' -or
    $messages -notmatch 'RADV matched PCI BDF: 0000:00:00.0' -or
    $messages -notmatch 'RADV direct display surface ready' -or
    $messages -notmatch 'RADV direct display swapchain ready' -or
    $messages -notmatch 'RADV direct display clear frame presented' -or
    $messages -notmatch 'RADV direct display triangle presented' -or
    $messages -notmatch 'RADV triangle shader modules ready' -or
    $messages -notmatch 'RADV triangle graphics pipeline ready' -or
    $messages -notmatch 'RADV triangle offscreen framebuffer ready' -or
    $messages -notmatch 'RADV triangle readback buffer ready' -or
    $messages -notmatch 'RADV offscreen triangle draw ready' -or
    $messages -notmatch 'RADV offscreen triangle pixels verified' -or
    $messages -notmatch 'RADV command submission and fence ready') {
    throw 'RADV loader probe lacks its physical device/submission gates.'
}
Write-Output "RADV loader probe: $output"
