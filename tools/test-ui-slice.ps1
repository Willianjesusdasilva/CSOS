param(
    [string]$Zig = ""
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if (-not $Zig) {
    $Zig = Join-Path $env:LOCALAPPDATA 'Temp/csos-zig/zig-x86_64-windows-0.15.2/zig.exe'
}
& $Zig run --dep ui_backend "-Mroot=$(Join-Path $workspace 'userspace/ui_slice.zig')" "-Mui_backend=$(Join-Path $workspace 'graphics/ui_backend.zig')"
if ($LASTEXITCODE -ne 0) { throw "Zig HTML UI vertical slice failed with exit code $LASTEXITCODE" }
Write-Output 'Zig HTML UI vertical slice passed'
$output = Join-Path $workspace '.zig-cache/csos_ui_html_demo.exe'
& $Zig cc -std=c11 -Wall -Werror (Join-Path $workspace 'userspace/csos_ui_html_demo.c') -I (Join-Path $workspace 'userspace') -o $output
if ($LASTEXITCODE -ne 0) { throw 'C ABI userspace compilation failed' }
& $output
if ($LASTEXITCODE -ne 0) { throw "C ABI HTML UI vertical slice failed with exit code $LASTEXITCODE" }
Write-Output 'C ABI HTML UI vertical slice passed'
