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

# Apply the same Windows copy/symlink repair to WebCore private headers.
$webCorePrivate = Join-Path $build 'WebCore\PrivateHeaders\WebCore'
$webCoreDerived = Join-Path $build 'WebCore\DerivedSources'
Get-ChildItem $webCorePrivate -File -ErrorAction SilentlyContinue | ForEach-Object {
    $raw = [IO.File]::ReadAllText($_.FullName)
    if ($raw.StartsWith("#pragma once`n#include ")) { return }
    $privateHash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    $candidate = Get-ChildItem (Join-Path $webkit 'Source\WebCore') -Recurse -File -Filter $_.Name -ErrorAction SilentlyContinue |
        Where-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash -eq $privateHash } |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $candidate) {
        $candidate = Get-ChildItem $webCoreDerived -Recurse -File -Filter $_.Name -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($candidate) {
        $relative = [IO.Path]::GetRelativePath($webCorePrivate, $candidate).Replace('\', '/')
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
$webCoreNested = ((Join-Path $build 'WebCore\PrivateHeaders\WebCore').Replace('\','/'))
$ninjaText = $ninjaText.Replace("-I$webCoreNested ", '')
# WebKit's Perl binding generator appends preprocessor flags itself.  A direct
# `zig.exe -E` is invalid, and embedding `c++` in the command is stripped by
# the generator's Windows argument parser.  Use the versioned wrapper so the
# Zig C++ driver remains explicit after Perl tokenization.
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$zig = ((Join-Path $repo '.tools\zig-x86_64-windows-0.16.0\zig.exe').Replace('\','/'))
$wrapper = ((Join-Path $repo 'tools\zig-cxx-preprocessor.cmd').Replace('\','/'))
$ninjaText = $ninjaText.Replace('"' + $zig + '" c++ -E', '"' + $wrapper + '"')
$ninjaText = $ninjaText.Replace('\"' + $zig + '\" c++ -E', '\"' + $wrapper + '\"')
$ninjaText = $ninjaText.Replace('"' + $zig + '" -E', '"' + $wrapper + '"')
$ninjaText = $ninjaText.Replace('\"' + $zig + '\" -E', '\"' + $wrapper + '\"')
$lolInclude = ((Join-Path $webkit 'Source\JavaScriptCore\lol').Replace('\','/'))
$soupInclude = ((Join-Path $repo '.tools\libsoup-src\libsoup').Replace('\','/'))
$soupGeneratedInclude = ((Join-Path $repo 'zig-out\libsoup-linux\libsoup').Replace('\','/'))
$badInspectorDir = ((Join-Path $build 'WebInspectorUI\DerivedSources\InspectorResources\WebInspectorUI').Replace('\','/'))
$intermediateInspectorDir = ((Join-Path $build 'WebInspectorUI\DerivedSources\InspectorResources').Replace('\','/'))
$goodInspectorDir = ((Join-Path $build 'WebInspectorUI').Replace('\','/'))
$ninjaText = $ninjaText.Replace("--sourcedir=$badInspectorDir", "--sourcedir=$goodInspectorDir")
$ninjaText = $ninjaText.Replace("--sourcedir=$intermediateInspectorDir", "--sourcedir=$goodInspectorDir")
$glibLib = ((Join-Path $sysrootPath 'lib\libglib-2.0.a').Replace('\','/'))
$gmoduleLib = ((Join-Path $sysrootPath 'lib\libgmodule-2.0.a').Replace('\','/'))
$pcre2Lib = ((Join-Path $sysrootPath 'lib\libpcre2-8.a').Replace('\','/'))
$ffiLib = ((Join-Path $sysrootPath 'lib\libffi.a').Replace('\','/'))
$ninjaText = $ninjaText.Replace("$glibLib C:/git/csos/zig-out/mesa-sysroot/usr/lib/libz.so", "$glibLib $gmoduleLib $pcre2Lib $ffiLib C:/git/csos/zig-out/mesa-sysroot/usr/lib/libz.so")
$zlib = 'C:/git/csos/zig-out/mesa-sysroot/usr/lib/libz.so'
$ninjaText = [regex]::Replace($ninjaText, ([regex]::Escape($glibLib) + '\s+' + [regex]::Escape($zlib)), "$glibLib $gmoduleLib $pcre2Lib $ffiLib $zlib")
$rules = Join-Path $build 'CMakeFiles\rules.ninja'
if (Test-Path -LiteralPath $rules) {
    $rulesText = [IO.File]::ReadAllText($rules)
    $rulesText = $rulesText.Replace('`n', [Environment]::NewLine)
    $compilePattern = '(?m)^  command = (?<prefix>.*zig\.exe c\+\+ -target x86_64-linux-musl )\$DEFINES \$INCLUDES \$FLAGS -MD -MT \$out -MF \$DEP_FILE -o \$out -c \$in\r?$'
    $compileReplacement = '  rspfile = $out.rsp' + [Environment]::NewLine + '  rspfile_content = $DEFINES $INCLUDES $FLAGS -MD -MT $out -MF $DEP_FILE' + [Environment]::NewLine + '  command = ${prefix}@$out.rsp -o $out -c $in'
    $rulesText = [regex]::Replace($rulesText, $compilePattern, $compileReplacement)
    [IO.File]::WriteAllText($rules, $rulesText, [Text.UTF8Encoding]::new($false))
}
$generatedScripts = Get-ChildItem $build -Recurse -File -Filter '*.bat' -ErrorAction SilentlyContinue
foreach ($script in $generatedScripts) {
    $scriptText = [IO.File]::ReadAllText($script.FullName)
    $updatedScript = $scriptText.Replace(('"' + $zig + '" c++ -E'), ('"' + $wrapper + '"'))
    $updatedScript = $updatedScript.Replace(('\\"' + $zig + '\\" c++ -E'), ('\\"' + $wrapper + '\\"'))
    $updatedScript = $updatedScript.Replace(('"' + $zig + '" -E'), ('"' + $wrapper + '"'))
    $updatedScript = $updatedScript.Replace(('\\"' + $zig + '\\" -E'), ('\\"' + $wrapper + '\\"'))
    $updatedScript = $updatedScript.Replace('zig.exe\" c++ -E', ('\"' + $wrapper + '\"'))
    $updatedScript = $updatedScript.Replace('zig.exe\" -E', ('\"' + $wrapper + '\"'))
    $updatedScript = $updatedScript.Replace('zig.exe" -E', ('"' + $wrapper + '"'))
    $preprocessorValue = '--preprocessor "\"' + $wrapper + '\" -P -x c++"'
    $updatedScript = [regex]::Replace($updatedScript, '--preprocessor .*? -P -x c\+\+"', $preprocessorValue)
    if ($updatedScript -ne $scriptText) {
        [IO.File]::WriteAllText($script.FullName, $updatedScript, [Text.UTF8Encoding]::new($false))
    }
}
if (-not $ninjaText.Contains("-I$lolInclude ")) {
    $ninjaText = $ninjaText.Replace('INCLUDES = ', "INCLUDES = -I$lolInclude ")
}
if (-not $ninjaText.Contains("-I$soupInclude ")) {
    $ninjaText = $ninjaText.Replace('INCLUDES = ', "INCLUDES = -I$soupInclude ")
}
if (-not $ninjaText.Contains("-I$soupGeneratedInclude ")) {
    $ninjaText = $ninjaText.Replace('INCLUDES = ', "INCLUDES = -I$soupGeneratedInclude ")
}
if (-not $ninjaText.Contains('-DSIMDUTF_IMPLEMENTATION_ICELAKE=0')) {
    $ninjaText = $ninjaText.Replace('FLAGS = ', 'FLAGS = -DSIMDUTF_IMPLEMENTATION_ICELAKE=0 ')
}
[IO.File]::WriteAllText($ninja, $ninjaText, [Text.UTF8Encoding]::new($false))
$dependencySuffix = " $gmoduleLib $pcre2Lib $ffiLib"
Get-ChildItem $build -Recurse -File -Filter '*.rsp' -ErrorAction SilentlyContinue | ForEach-Object {
    $rspText = [IO.File]::ReadAllText($_.FullName)
    if ($rspText.Contains('libglib-2.0.a') -and -not $rspText.Contains('libpcre2-8.a')) {
        [IO.File]::WriteAllText($_.FullName, ($rspText.TrimEnd() + $dependencySuffix + "`n"), [Text.UTF8Encoding]::new($false))
    }
}

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
