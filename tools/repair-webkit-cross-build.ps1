param(
    [string]$BuildDirectory = (Join-Path $PSScriptRoot '..\zig-out\webkit-linux6'),
    [string]$Sysroot = (Join-Path $PSScriptRoot '..\zig-out\mesa-sysroot\usr'),
    [string]$WebKitSource = (Join-Path $PSScriptRoot '..\.tools\webkit-src'),
    [string]$IcuSource = (Join-Path $PSScriptRoot '..\.tools\icu-cross-src'),
    [string]$GlibSource = (Join-Path $PSScriptRoot '..\.tools\glib-src'),
    [string]$GlibBuild = (Join-Path $PSScriptRoot '..\zig-out\glib-linux8')
)

$ErrorActionPreference = 'Stop'
function Get-RelativePathCompat([string]$From, [string]$To) {
    $fromUri = [Uri]((Resolve-Path -LiteralPath $From).Path + [IO.Path]::DirectorySeparatorChar)
    $toUri = [Uri]((Resolve-Path -LiteralPath $To).Path)
    return [Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()).Replace('/', '\')
}
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
        $relative = (Get-RelativePathCompat $private $candidate).Replace('\', '/')
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
        $relative = (Get-RelativePathCompat $webCorePrivate $candidate).Replace('\', '/')
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
$soupServerInclude = ((Join-Path $repo '.tools\libsoup-src\libsoup\server').Replace('\','/'))
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
    $shortBuild = 'C:/w/zig-out/webkit-linux6'
    $compileReplacement = "  rspfile = $shortBuild/`$out.rsp" + [Environment]::NewLine + '  rspfile_content = $DEFINES $INCLUDES $FLAGS -MD -MT $out -MF $DEP_FILE' + [Environment]::NewLine + "  command = `${prefix}@${shortBuild}/`$out.rsp -o `$out -c `$in"
    $rulesText = [regex]::Replace($rulesText, $compilePattern, $compileReplacement)
    $rulesText = $rulesText.Replace('rspfile = $out.rsp', "rspfile = $shortBuild/`$out.rsp")
    $rulesText = $rulesText.Replace('@$out.rsp', "@${shortBuild}/`$out.rsp")
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
# Ninja emits Windows output paths with a backslash before the filename when
# the output lives below a short junction (for example C:/w/...\file).  Git's
# Perl/GCC inspector generator treats that backslash as a literal character.
# Normalize the generated inspector preprocessor paths before invoking it.
$inspectorPreprocess = Join-Path $webkit 'Source\JavaScriptCore\inspector\scripts\codegen\preprocess.pl'
if (Test-Path -LiteralPath $inspectorPreprocess) {
    $preprocessText = [IO.File]::ReadAllText($inspectorPreprocess)
    $normalizer = 'my $pid = 0;'
    $normalizerCode = '$inputPath =~ s{\\}{/}g;' + "`r`n" + '$outputPath =~ s{\\}{/}g;' + "`r`n" + 'if ($inputPath =~ /^([A-Za-z]):\/(.*)$/) { $inputPath = "/" . lc($1) . "/" . $2; }'
    if (-not $preprocessText.Contains($normalizerCode)) {
        $preprocessText = $preprocessText.Replace($normalizer, ($normalizerCode + "`r`n" + $normalizer))
        [IO.File]::WriteAllText($inspectorPreprocess, $preprocessText, [Text.UTF8Encoding]::new($false))
    }
}
if (-not $ninjaText.Contains("-I$lolInclude ")) {
    $ninjaText = $ninjaText.Replace('INCLUDES = ', "INCLUDES = -I$lolInclude ")
}
if (-not $ninjaText.Contains("-I$soupInclude ")) {
    # The installed libsoup headers must remain the canonical include tree;
    # mixing the source tree with it causes duplicate GLib autoptr symbols.
}
if (-not $ninjaText.Contains("-I$soupServerInclude ")) {
    # Server-only headers are staged below instead of adding a second tree.
}
$ninjaText = $ninjaText.Replace("-I$soupInclude ", '').Replace("-I$soupServerInclude ", '')
$ninjaText = $ninjaText.Replace('-IC:/w/.tools/libsoup-src/libsoup ', '').Replace('-IC:/w/.tools/libsoup-src/libsoup/server ', '')
$ninjaText = $ninjaText.Replace('-IC:/git/csos/zig-out/libsoup-linux/libsoup ', '').Replace('-IC:/w/zig-out/libsoup-linux/libsoup ', '')
if (-not $ninjaText.Contains('-DSIMDUTF_IMPLEMENTATION_ICELAKE=0')) {
    $ninjaText = $ninjaText.Replace('FLAGS = ', 'FLAGS = -DSIMDUTF_IMPLEMENTATION_ICELAKE=0 ')
}
[IO.File]::WriteAllText($ninja, $ninjaText, [Text.UTF8Encoding]::new($false))
$cairoFeatures = Join-Path $sysrootPath 'include\cairo\cairo-features.h'
if (-not (Test-Path -LiteralPath $cairoFeatures)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $cairoFeatures) | Out-Null
    $cairoText = @'
#ifndef CAIRO_FEATURES_H
#define CAIRO_FEATURES_H
#define CAIRO_HAS_IMAGE_SURFACE 1
#define CAIRO_HAS_RECORDING_SURFACE 1
#define CAIRO_HAS_PNG_FUNCTIONS 1
#define CAIRO_HAS_FT_FONT 1
#define CAIRO_HAS_FC_FONT 1
#define CAIRO_HAS_USER_FONT 1
#define CAIRO_HAS_MESH 1
#define CAIRO_HAS_RASTER_SOURCE 1
#define CAIRO_HAS_SCRIPT_SURFACE 0
#define CAIRO_HAS_PDF_SURFACE 0
#define CAIRO_HAS_PS_SURFACE 0
#define CAIRO_HAS_SVG_SURFACE 0
#define CAIRO_HAS_XLIB_SURFACE 0
#define CAIRO_HAS_XCB_SURFACE 0
#define CAIRO_HAS_QUARTZ_SURFACE 0
#define CAIRO_HAS_WIN32_SURFACE 0
#define CAIRO_HAS_OPENGL_SURFACE 0
#endif
'@
    [IO.File]::WriteAllText($cairoFeatures, $cairoText.TrimStart(), [Text.UTF8Encoding]::new($false))
}
# The cross sysroot carries the public FreeType headers but not its generated
# config subtree.  Stage that subtree so <freetype/config/ftheader.h> resolves.
$freetypeConfig = Join-Path $sysrootPath 'include\freetype2\freetype\config'
New-Item -ItemType Directory -Force -Path $freetypeConfig | Out-Null
Copy-Item -Force -Recurse (Join-Path $repo '.tools\freetype-src\include\freetype\config\*') $freetypeConfig
# libsoup's generated public tree omits headers from its auth/content/server
# subtrees on this host. Copy the subdirectories into the installed tree
# rather than adding a duplicate -I path that would redefine common types.
$soupInstalled = Join-Path $sysrootPath 'include\libsoup-3.0\libsoup'
New-Item -ItemType Directory -Force -Path $soupInstalled | Out-Null
$soupInstalledRoot = Join-Path $sysrootPath 'include\libsoup-3.0'
New-Item -ItemType Directory -Force -Path $soupInstalledRoot | Out-Null
$soupSource = Join-Path $repo '.tools\libsoup-src\libsoup'
Get-ChildItem $soupSource -Directory | ForEach-Object {
    Copy-Item -Force -Recurse $_.FullName $soupInstalled
    Copy-Item -Force -Recurse $_.FullName $soupInstalledRoot
}
Copy-Item -Force (Join-Path $soupSource '*.h') $soupInstalled
# soup-server.h uses an unqualified websocket include; mirror those public
# headers beside the server headers so that the installed tree resolves it
# without adding a second, conflicting include root.
Copy-Item -Force (Join-Path $soupSource 'websocket\*.h') (Join-Path $soupInstalled 'server')
$soupEnumHeader = Join-Path $repo 'zig-out\libsoup-linux\libsoup\soup-enum-types.h'
if (Test-Path -LiteralPath $soupEnumHeader) {
    Copy-Item -Force $soupEnumHeader $soupInstalledRoot
    Copy-Item -Force $soupEnumHeader $soupInstalled
}
$soupVersionGenerator = Join-Path $soupSource 'generate-version-header.py'
$soupVersionTemplate = Join-Path $soupSource 'soup-version.h.in'
foreach ($soupVersionOutput in @(
    (Join-Path $soupInstalledRoot 'soup-version.h'),
    (Join-Path $soupInstalled 'soup-version.h'))) {
    & python $soupVersionGenerator $soupVersionTemplate $soupVersionOutput '3.6.5'
    if ($LASTEXITCODE -ne 0) { throw "Could not generate libsoup version header" }
}
# The upstream headers have no include guards.  Keep one canonical copy under
# libsoup/ and make the flat include directory wrappers; otherwise a mix of
# <soup-foo.h> and <libsoup/soup-foo.h> defines every type twice.
Get-ChildItem $soupInstalledRoot -File -Filter '*.h' | Remove-Item -Force
Get-ChildItem $soupInstalled -File -Filter '*.h' | ForEach-Object {
    $wrapper = Join-Path $soupInstalledRoot $_.Name
    $includeName = "libsoup/$((Get-RelativePathCompat $soupInstalled $_.FullName).Replace('\','/'))"
    [IO.File]::WriteAllText($wrapper, "#pragma once`n#include <$includeName>`n", [Text.UTF8Encoding]::new($false))
}
# Some upstream server headers reuse names from the common public tree and
# include websocket headers without a directory qualifier. Make those paths
# wrappers to the canonical copies instead of exposing duplicate definitions.
[IO.File]::WriteAllText((Join-Path $soupInstalled 'server\soup-message-body.h'), "#pragma once`n#include <libsoup/soup-message-body.h>`n", [Text.UTF8Encoding]::new($false))
Get-ChildItem (Join-Path $soupInstalled 'websocket') -File -Filter '*.h' | ForEach-Object {
    $rootWrapper = Join-Path $soupInstalledRoot $_.Name
    $serverWrapper = Join-Path $soupInstalled 'server' $_.Name
    $includeName = "libsoup/websocket/$($_.Name)"
    $text = "#pragma once`n#include <$includeName>`n"
    [IO.File]::WriteAllText($rootWrapper, $text, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($serverWrapper, $text, [Text.UTF8Encoding]::new($false))
}
$dependencySuffix = " $gmoduleLib $pcre2Lib $ffiLib"
Get-ChildItem $build -Recurse -File -Filter '*.rsp' -ErrorAction SilentlyContinue | ForEach-Object {
    $rspText = [IO.File]::ReadAllText($_.FullName)
    $rspText = $rspText.Replace('-IC:/git/csos/zig-out/libsoup-linux/libsoup ', '').Replace('-IC:/w/zig-out/libsoup-linux/libsoup ', '')
    $rspText = $rspText.Replace('-IC:/w/.tools/libsoup-src/libsoup ', '').Replace('-IC:/w/.tools/libsoup-src/libsoup/server ', '')
    if ($rspText.Contains('libglib-2.0.a') -and -not $rspText.Contains('libpcre2-8.a')) {
        [IO.File]::WriteAllText($_.FullName, ($rspText.TrimEnd() + $dependencySuffix + "`n"), [Text.UTF8Encoding]::new($false))
    } else {
        [IO.File]::WriteAllText($_.FullName, $rspText, [Text.UTF8Encoding]::new($false))
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
