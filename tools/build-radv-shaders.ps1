$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$glslang = Join-Path $workspace '.tools/glslang-16.5.0/bin/glslang.exe'
$output = Join-Path $workspace 'zig-out/radv-shaders'
& "$PSScriptRoot/prepare-glslang.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Pinned glslang verification failed.' }
if (-not (Test-Path -LiteralPath $glslang)) { throw 'Pinned glslang is unavailable.' }
New-Item -ItemType Directory -Force -Path $output | Out-Null
$vertex = Join-Path $output 'triangle.vert.spv'
$fragment = Join-Path $output 'triangle.frag.spv'
& $glslang -V --target-env vulkan1.0 -S vert -o $vertex "$workspace/userspace/shaders/radv_triangle.vert"
if ($LASTEXITCODE -ne 0) { throw 'Vertex shader compilation failed.' }
& $glslang -V --target-env vulkan1.0 -S frag -o $fragment "$workspace/userspace/shaders/radv_triangle.frag"
if ($LASTEXITCODE -ne 0) { throw 'Fragment shader compilation failed.' }
& python "$PSScriptRoot/embed-radv-shaders.py" $vertex $fragment "$output/radv_triangle_shaders.h"
if ($LASTEXITCODE -ne 0) { throw 'SPIR-V embedding failed.' }
Get-FileHash -Algorithm SHA256 -LiteralPath $vertex, $fragment | ForEach-Object {
    Write-Output "$($_.Path): $($_.Hash)"
}
