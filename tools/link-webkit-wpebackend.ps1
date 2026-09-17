param(
    [string]$Build = 'C:/w/zig-out/webkit-linux6',
    [string]$Backend = 'C:/git/csos/zig-out/wpebackend-fdo-linux5/libWPEBackend-fdo-1.0.so.1.10.2'
)

$ErrorActionPreference = 'Stop'
$ninja = 'C:/w/.tools/mesa-build-env/Scripts/ninja.exe'
$buildPath = (Resolve-Path $Build).Path
$baseRspCandidates = @(
    (Join-Path $buildPath 'CMakeFiles/WebKit.rsp'),
    (Join-Path $buildPath 'CMakeFiles/WebKit-link.rsp'),
    (Join-Path $buildPath 'CMakeFiles/WebKit.rsp.pre-wpe-backend')
)
$baseRsp = $baseRspCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$csosRsp = Join-Path $buildPath 'CMakeFiles/WebKit-csos.rsp'
$target = 'lib/libWPEWebKit-2.0.so.1.9.10'

foreach ($path in @($ninja, $baseRsp, $Backend)) {
    if (-not (Test-Path $path)) { throw "Required path not found: $path" }
}

$sysrootLib = 'C:/git/csos/zig-out/mesa-sysroot/usr/lib'
$extras = @(
    "$sysrootLib/libpixman-1.a",
    "$sysrootLib/libpsl.a",
    $Backend,
    "$sysrootLib/libpcre2-8.a",
    "$sysrootLib/libffi.a",
    "$sysrootLib/libexpat.a"
)
foreach ($path in $extras) {
    if (-not (Test-Path $path)) { throw "Required link input not found: $path" }
}

$base = (Get-Content $baseRsp -Raw).TrimEnd()
# Older repair builds appended a zero-filled local loader stub.  Keeping that
# object gives libWPE's static loader a private interface and prevents the real
# backend's _wpe_loader_interface from being used at runtime.
$base = [regex]::Replace($base, '(?i)(?:[^\s]*[/\\])?wpe-loader-link-stub\.o\s*', '')
Set-Content $csosRsp ($base + " `r`n" + ($extras -join " `r`n")) -NoNewline

$command = (& $ninja -C $buildPath -t commands $target | Select-Object -Last 1)
if (-not $command) { throw 'Ninja did not return a WebKit link command' }
$command = $command.Replace('@CMakeFiles\WebKit.rsp', '@CMakeFiles\WebKit-csos.rsp')

Push-Location $buildPath
try {
    & cmd.exe /c $command
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}

Write-Host "Linked WebKit with WPE backend: $(Join-Path $buildPath $target)"
