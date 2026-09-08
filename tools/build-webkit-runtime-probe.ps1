$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$output = Join-Path $workspace 'zig-out/webkit-runtime-probe'
& "$workspace/.tools/zig-x86_64-windows-0.16.0/zig.exe" build-exe `
    "$workspace/userspace/webkit_runtime_probe.zig" -target x86_64-linux-musl `
    -O ReleaseSmall -lc -static "-femit-bin=$output"
if ($LASTEXITCODE -ne 0) { throw 'WebKit prerequisite probe compilation failed.' }
Write-Output "Built musl pthread prerequisite probe (not WebKit): $output"
