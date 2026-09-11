param(
    [string]$Build = 'C:/w/zig-out/webkit-linux6',
    [string]$Output = 'C:/git/csos/zig-out/webkit-launcher'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
$zig = Join-Path $root '.tools/zig-x86_64-windows-0.16.0/zig.exe'
$sysroot = Join-Path $root 'zig-out/mesa-sysroot'
$webkitInclude = "$Build/DerivedSources/ForwardingHeaders/wpe/wpe"
$webkitGenerated = "$Build/DerivedSources/WebKit"
$include = @(
    "-I$webkitInclude",
    "-I$webkitGenerated",
    "-I$Build/JavaScriptCoreGLib/Headers",
    "-I$Build/JavaScriptCoreGLib/DerivedSources",
    "-I$sysroot/usr/include",
    "-I$sysroot/usr/include/glib-2.0",
    "-I$sysroot/usr/lib/glib-2.0/include",
    "-I$sysroot/usr/include/libsoup-3.0",
    "-I$sysroot/usr/include/wpe-1.0",
    '-fPIC'
)
$lib = Join-Path $sysroot 'usr/lib'
$relativeOutput = 'zig-out/webkit-launcher'
if ([IO.Path]::GetFullPath($Output) -ne [IO.Path]::GetFullPath((Join-Path $root $relativeOutput))) {
    throw 'Output must be inside the workspace at zig-out/webkit-launcher (Zig Windows path parser limitation).'
}
$zigArgs = @('build-exe', 'userspace/webkit_launcher.zig', '-target', 'x86_64-linux-musl', '-O', 'ReleaseSafe', ('-femit-bin=' + $relativeOutput)) + $include + @(
    ("-L$Build/lib"),
    ("-L$lib"),
    "$Build/lib/libWPEWebKit-2.0.so.1.9.10",
    'C:/git/csos/zig-out/wpebackend-fdo-linux5/libWPEBackend-fdo-1.0.so.1.10.2',
    '-lwpe-1.0', '-lglib-2.0', '-lgobject-2.0', '-lgio-2.0', '-lpcre2-8', '-lepoxy', '-lxkbcommon', '-lffi', '-lz', '-ldl', '-lm', '-lc'
)
Push-Location $root
try {
    & $zig @zigArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}
Write-Host "Built WPE launcher: $Output"
