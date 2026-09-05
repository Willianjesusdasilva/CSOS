param([string]$SourceDirectory = "$PSScriptRoot/../.tools/libdrm-src", [switch]$AmdGpu)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = (Resolve-Path $SourceDirectory).Path
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne '773536b1e5dde694dd743815528aff8bb2cf2cc3') {
    throw 'The libdrm probe requires upstream revision 773536b1e5dde694dd743815528aff8bb2cf2cc3.'
}
$changes = & git -C $source status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Use an unmodified libdrm source checkout.' }
$output = Join-Path $workspace 'zig-out/libdrm-probe'
New-Item -ItemType Directory -Force -Path $output | Out-Null
& python "$source/gen_table_fourcc.py" "$source/include/drm/drm_fourcc.h" "$output/generated_static_table_fourcc.h"
if ($LASTEXITCODE -ne 0) { throw 'libdrm table generation failed.' }
$sources = @('xf86drm.c', 'xf86drmHash.c', 'xf86drmRandom.c', 'xf86drmSL.c', 'xf86drmMode.c') |
    ForEach-Object { Join-Path $source $_ }
$extraFlags = @()
$binary = 'libdrm-probe'
if ($AmdGpu) {
    $sources += @('amdgpu_asic_id.c', 'amdgpu_bo.c', 'amdgpu_cs.c', 'amdgpu_device.c',
        'amdgpu_gpu_info.c', 'amdgpu_vamgr.c', 'amdgpu_vm.c', 'handle_table.c', 'amdgpu_userq.c') |
        ForEach-Object { Join-Path "$source/amdgpu" $_ }
    $extraFlags = @('-DCSOS_PROBE_AMDGPU=1', '-pthread', '-I', "$source/amdgpu")
    $binary = 'libdrm-amdgpu-probe'
}
& "$workspace/.tools/zig-x86_64-windows-0.16.0/zig.exe" cc -target x86_64-linux-musl -static -Os `
    -ffunction-sections -fdata-sections '-Wl,--gc-sections' `
    -include "$workspace/tests/libdrm_config.h" -I $source -I "$source/include/drm" -I $output `
    @extraFlags "$workspace/userspace/libdrm_probe.c" @sources -o "$output/$binary"
if ($LASTEXITCODE -ne 0) { throw 'libdrm probe compilation failed.' }
Write-Output "Built upstream libdrm probe: $output/$binary"
