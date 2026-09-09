param(
    [string]$BuildDirectory = (Join-Path $PSScriptRoot '..\zig-out\webkit-linux6'),
    [string]$Sysroot = (Join-Path $PSScriptRoot '..\zig-out\mesa-sysroot\usr'),
    [string]$WebKitSource = (Join-Path $PSScriptRoot '..\.tools\webkit-src'),
    [string]$IcuSource = (Join-Path $PSScriptRoot '..\.tools\icu-cross-src'),
    [string]$GlibSource = (Join-Path $PSScriptRoot '..\.tools\glib-src'),
    [string]$GlibBuild = (Join-Path $PSScriptRoot '..\zig-out\glib-linux8')
)

$ErrorActionPreference = 'Stop'
$build = [IO.Path]::GetFullPath($BuildDirectory)
$sysrootPath = [IO.Path]::GetFullPath($Sysroot)
$webkit = [IO.Path]::GetFullPath($WebKitSource)
$icu = [IO.Path]::GetFullPath($IcuSource)
$glib = [IO.Path]::GetFullPath($GlibSource)
$glibBuildPath = [IO.Path]::GetFullPath($GlibBuild)
foreach ($path in @($build, $sysrootPath, $webkit, $icu, $glib, $glibBuildPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required WebKit cross-build path not found: $path" }
}

# Windows without Developer Mode cannot create the symlinks expected by WebKit.
# Flattened private headers then become independent copies and Clang sees the
# same class twice through two paths. Replace byte-identical copies with a
# relative include wrapper so the source header has one canonical definition.
$private = Join-Path $build 'JavaScriptCore\PrivateHeaders\JavaScriptCore'
$derived = Join-Path $build 'JavaScriptCore\DerivedSources'
$sourceFiles = @{}
Get-ChildItem (Join-Path $webkit 'Source\JavaScriptCore') -Recurse -File -Include '*.h','*.hpp' | ForEach-Object {
    if (-not $sourceFiles.ContainsKey($_.Name)) { $sourceFiles[$_.Name] = $_.FullName }
}
Get-ChildItem $private -File -ErrorAction SilentlyContinue | ForEach-Object {
    $raw = [IO.File]::ReadAllText($_.FullName)
    if ($raw.StartsWith("#pragma once`n#include ")) { return }
    $candidate = $null
    if ($sourceFiles.ContainsKey($_.Name)) {
        $sourcePath = $sourceFiles[$_.Name]
        if ((Get-FileHash $_.FullName -Algorithm SHA256).Hash -eq (Get-FileHash $sourcePath -Algorithm SHA256).Hash) { $candidate = $sourcePath }
    }
    if ($null -eq $candidate) {
        $candidate = Get-ChildItem $derived -Recurse -File -Filter $_.Name -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($candidate) {
        $relative = [IO.Path]::GetRelativePath($private, $candidate).Replace('\', '/')
        [IO.File]::WriteAllText($_.FullName, "#pragma once`n#include `"$relative`"`n", [Text.UTF8Encoding]::new($false))
    }
}

# The generated target currently inherits the nested private-header include
# directory, which reintroduces the duplicate path on a Windows configure.
$ninja = Join-Path $build 'build.ninja'
if (-not (Test-Path -LiteralPath $ninja)) { throw "Ninja file not found: $ninja" }
$ninjaText = [IO.File]::ReadAllText($ninja)
$nested = ((Join-Path $build 'JavaScriptCore\PrivateHeaders\JavaScriptCore').Replace('\','/'))
$ninjaText = $ninjaText.Replace("-I$nested ", '')
$lolInclude = ((Join-Path $webkit 'Source\JavaScriptCore\lol').Replace('\','/'))
if (-not $ninjaText.Contains("-I$lolInclude ")) {
    $ninjaText = $ninjaText.Replace('INCLUDES = ', "INCLUDES = -I$lolInclude ")
}
if (-not $ninjaText.Contains('-DSIMDUTF_IMPLEMENTATION_ICELAKE=0')) {
    $ninjaText = $ninjaText.Replace('FLAGS = ', 'FLAGS = -DSIMDUTF_IMPLEMENTATION_ICELAKE=0 ')
}
[IO.File]::WriteAllText($ninja, $ninjaText, [Text.UTF8Encoding]::new($false))

# Promote target ICU and the generated GLib module headers into the common
# musl sysroot used by WebKit's CMake toolchain.
$include = Join-Path $sysrootPath 'include'
$lib = Join-Path $sysrootPath 'lib'
New-Item -ItemType Directory -Force -Path (Join-Path $include 'unicode'), $lib | Out-Null
Copy-Item -Force -Recurse (Join-Path $icu 'common\unicode\*') (Join-Path $include 'unicode')
Copy-Item -Force (Join-Path $icu 'i18n\unicode\*') (Join-Path $include 'unicode')
Copy-Item -Force (Join-Path $icu 'lib\libicui18n.a'), (Join-Path $icu 'lib\libicuuc.a'), (Join-Path $icu 'lib\libicuio.a'), (Join-Path $icu 'stubdata\libicudata.a') $lib
Copy-Item -Force (Join-Path $glib 'gmodule\gmodule.h') (Join-Path $include 'glib-2.0\gmodule.h')
Copy-Item -Force (Join-Path $glibBuildPath 'gmodule\gmoduleconf.h') (Join-Path $include 'glib-2.0\gmoduleconf.h')
Write-Output "WebKit cross build repaired: $build"
