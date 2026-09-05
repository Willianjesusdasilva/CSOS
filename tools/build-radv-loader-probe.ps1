$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$zig = Join-Path $workspace '.tools/zig-x86_64-windows-0.16.0/zig.exe'
$sysrootLib = Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib'
$source = Join-Path $workspace 'userspace/radv_loader_probe.c'
$output = Join-Path $workspace 'zig-out/radv-loader-probe'
$radv = Join-Path $sysrootLib 'libvulkan_radeon.so'
if (-not (Test-Path -LiteralPath $radv)) { throw 'Build the stripped RADV runtime first.' }
& $zig cc -target x86_64-linux-musl -O2 -fPIE -pie -nostdlib `
    '-Wl,--dynamic-linker=/lib/ld-csos.so' '-Wl,--no-as-needed' `
    "-I$workspace/.tools/mesa-src/include" $source $radv "$sysrootLib/libdrm.so.2" -o $output
if ($LASTEXITCODE -ne 0) { throw 'Failed to build RADV loader probe.' }
$readelf = (Get-Command readelf.exe -ErrorAction Stop).Source
$dynamic = (& $readelf -dW $output) -join "`n"
$programs = (& $readelf -lW $output) -join "`n"
if ($dynamic -notmatch '\(NEEDED\).*\[libvulkan_radeon\.so\]' -or
    $programs -notmatch 'Requesting program interpreter:\s*/lib/ld-csos\.so') {
    throw 'RADV loader probe lacks its required CSOS dynamic-link contract.'
}
Write-Output "RADV loader probe: $output"
