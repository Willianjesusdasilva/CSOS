param(
    [string]$BuildDirectory = (Join-Path $PSScriptRoot '..\zig-out\webkit-linux6'),
    [string]$Sysroot = (Join-Path $PSScriptRoot '..\zig-out\mesa-sysroot\usr'),
    [string]$WebKitSource = (Join-Path $PSScriptRoot '..\.tools\webkit-src'),
    [string]$IcuSource = (Join-Path $PSScriptRoot '..\.tools\icu-cross-src'),
    [string]$GlibSource = (Join-Path $PSScriptRoot '..\.tools\glib-src'),
    [string]$GlibBuild = (Join-Path $PSScriptRoot '..\zig-out\glib-linux8'),
    [string]$JpegBuild = (Join-Path $PSScriptRoot '..\zig-out\jpeg-turbo-linux'),
    [string]$EpoxySource = (Join-Path $PSScriptRoot '..\.tools\libepoxy-src'),
    [string]$EpoxyBuild = (Join-Path $PSScriptRoot '..\zig-out\libepoxy-linux')
)

$ErrorActionPreference = 'Stop'
function Get-RelativePathCompat([string]$From, [string]$To) {
    $fromUri = [Uri]((Resolve-Path -LiteralPath $From).Path + [IO.Path]::DirectorySeparatorChar)
    $toUri = [Uri]((Resolve-Path -LiteralPath $To).Path)
    return [Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()).Replace('/', '\')
}
function Write-TextRetry([string]$Path, [string]$Content) {
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        try {
            [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
            return
        } catch [IO.IOException] {
            if ($attempt -eq 7) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}
$build = [IO.Path]::GetFullPath($BuildDirectory)
$sysrootPath = [IO.Path]::GetFullPath($Sysroot)
$webkit = [IO.Path]::GetFullPath($WebKitSource)
$icu = [IO.Path]::GetFullPath($IcuSource)
$glib = [IO.Path]::GetFullPath($GlibSource)
$glibBuildPath = [IO.Path]::GetFullPath($GlibBuild)
$jpegBuildPath = [IO.Path]::GetFullPath($JpegBuild)
$epoxySourcePath = [IO.Path]::GetFullPath($EpoxySource)
$epoxyBuildPath = [IO.Path]::GetFullPath($EpoxyBuild)
foreach ($path in @($build, $sysrootPath, $webkit, $icu, $glib, $glibBuildPath, $jpegBuildPath, $epoxySourcePath, $epoxyBuildPath)) {
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
        # The generated private tree may normalize line endings or add a
        # generated prologue, so a hash comparison is not reliable here.  A
        # same-named upstream header is canonical and must be forwarded rather
        # than copied; otherwise Clang sees two independent definitions.
        $candidate = $sourcePath
    }
    if ($null -eq $candidate) {
        $candidate = Get-ChildItem $derived -Recurse -File -Filter $_.Name -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($candidate) {
        $relative = (Get-RelativePathCompat $private $candidate).Replace('\', '/')
        Write-TextRetry $_.FullName "#pragma once`n#include `"$relative`"`n"
    }
}

# Apply the same Windows copy/symlink repair to WebCore private headers.
$webCorePrivate = Join-Path $build 'WebCore\PrivateHeaders\WebCore'
$webCoreDerived = Join-Path $build 'WebCore\DerivedSources'
$webCorePrivateSources = @{}
$ninjaForWebCoreMap = Join-Path $build 'build.ninja'
if (Test-Path -LiteralPath $ninjaForWebCoreMap) {
    Get-Content -LiteralPath $ninjaForWebCoreMap | ForEach-Object {
        if ($_ -match '^build WebCore/PrivateHeaders/WebCore/([^ |]+).*CUSTOM_COMMAND (\S+)') {
            $webCorePrivateSources[$matches[1]] = $matches[2]
        }
    }
}
Get-ChildItem $webCorePrivate -File -ErrorAction SilentlyContinue | ForEach-Object {
    $raw = [IO.File]::ReadAllText($_.FullName)
    # Re-evaluate existing wrappers too: a prior basename-only repair may
    # have selected the wrong duplicate source (for example the CF variant).
    # CMake records the exact source path for every flattened private header;
    # use that mapping because WebCore contains repeated basenames (for
    # example platform/network/{soup,cf}/ResourceError.h).
    $candidate = $null
    if ($webCorePrivateSources.ContainsKey($_.Name)) {
        $candidate = $webCorePrivateSources[$_.Name].Replace('/', '\')
        $candidate = $candidate.Replace('C:\w\.tools\webkit-src', $webkit)
        $candidate = $candidate.Replace('C$:\w\.tools\webkit-src', $webkit)
        if ($candidate -like 'WebCore\DerivedSources\*') { $candidate = Join-Path $build $candidate }
        if (-not ($candidate -match '^[A-Za-z]:\\')) { $candidate = Join-Path $webkit $candidate }
    }
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) {
        $candidate = Get-ChildItem (Join-Path $webkit 'Source\WebCore') -Recurse -File -Filter $_.Name -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $candidate) {
        $candidate = Get-ChildItem $webCoreDerived -Recurse -File -Filter $_.Name -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($candidate) {
        $relative = (Get-RelativePathCompat $webCorePrivate $candidate).Replace('\', '/')
        Write-TextRetry $_.FullName "#pragma once`n#include `"$relative`"`n"
    }
}

# Serializer inputs are consumed by a Python parser, not by the C/C++
# preprocessor. A relative include wrapper is therefore not valid here: the
# parser would see only the include directive and omit the type definitions.
# Materialize the generated .serialization.in contents in the private tree.
Get-ChildItem $webCorePrivate -File -Filter '*.serialization.in' -ErrorAction SilentlyContinue | ForEach-Object {
    $sourceSerialization = $null
    if ($webCorePrivateSources.ContainsKey($_.Name)) {
        $mappedSerialization = $webCorePrivateSources[$_.Name].Replace('/', '\')
        $mappedSerialization = $mappedSerialization.Replace('C:\w\.tools\webkit-src', $webkit)
        $mappedSerialization = $mappedSerialization.Replace('C$:\w\.tools\webkit-src', $webkit)
        if ($mappedSerialization -like 'WebCore\DerivedSources\*') {
            $mappedSerialization = Join-Path $build $mappedSerialization
        }
        if ($mappedSerialization -match '^[A-Za-z]:\\') {
            $sourceSerialization = $mappedSerialization
        }
    }
    if (-not $sourceSerialization) {
        $wrapperText = [IO.File]::ReadAllText($_.FullName)
        if ($wrapperText -match '\.tools[\\/]webkit-src[\\/](Source[\\/].*?\.serialization\.in)') {
            $sourceSerialization = Join-Path $webkit ($matches[1].Replace('/', '\'))
        }
    }
    if (-not $sourceSerialization) {
        $sourceSerialization = Join-Path $webCoreDerived $_.Name
    }
    if (Test-Path -LiteralPath $sourceSerialization) {
        $serializationText = [IO.File]::ReadAllText($sourceSerialization)
        if ([IO.File]::ReadAllText($_.FullName) -ne $serializationText) {
            Write-TextRetry $_.FullName $serializationText
        }
    }
}

# The generated target currently inherits the nested private-header include
# directory, which reintroduces the duplicate path on a Windows configure.
$ninja = Join-Path $build 'build.ninja'
if (-not (Test-Path -LiteralPath $ninja)) { throw "Ninja file not found: $ninja" }
$ninjaText = [IO.File]::ReadAllText($ninja)
# GLib ships the canonical gdbus-codegen implementation as a Python script,
# but the Windows cross-build does not provide the Unix launcher on PATH.
# Invoke that bundled generator directly so WebCore's AT-SPI interfaces remain
# generated from the upstream XML rather than being replaced with stubs.
$pythonExe = ((Get-Command python.exe -ErrorAction Stop).Source).Replace('\', '/')
$glibCodegenWrapper = 'C:/w/tools/gdbus-codegen-wrapper.py'
$ninjaText = $ninjaText.Replace('gdbus-codegen ', '"' + $pythonExe + '" "' + $glibCodegenWrapper + '" ')
$ninjaText = $ninjaText.Replace('C:/w/.tools/glib-src/gio/gdbus-2.0/codegen/codegen.py', $glibCodegenWrapper)
$glibMkenums = 'C:/w/zig-out/glib-host2/gobject/glib-mkenums'
$ninjaText = $ninjaText.Replace('glib-mkenums ', '"' + $pythonExe + '" "' + $glibMkenums + '" ')
$glibResources = 'C:/git/csos/zig-out/glib-host2/gio/glib-compile-resources.exe'
$glibResourcesW = 'C:/w/zig-out/glib-host2/gio/glib-compile-resources.exe'
$glibResourcesWin = 'C:\git\csos\zig-out\glib-host2\gio\glib-compile-resources.exe'
$glibResourcesWW = 'C:\w\zig-out\glib-host2\gio\glib-compile-resources.exe'
$glibResourcesWrapper = 'C:/w/tools/glib-compile-resources-wrapper.py'
$serializerGenerator = 'C:/w/.tools/webkit-src/Source/WebKit/Scripts/generate-serializers.py'
$serializerWrapper = 'C:/w/tools/generate-serializers-wrapper.py'
$ninjaText = $ninjaText.Replace($glibResources, '"' + $pythonExe + '" "' + $glibResourcesWrapper + '"')
$ninjaText = $ninjaText.Replace($glibResourcesW, '"' + $pythonExe + '" "' + $glibResourcesWrapper + '"')
$ninjaText = $ninjaText.Replace($glibResourcesWin, '"' + $pythonExe + '" "' + $glibResourcesWrapper + '"')
$ninjaText = $ninjaText.Replace($glibResourcesWW, '"' + $pythonExe + '" "' + $glibResourcesWrapper + '"')
$textFilter = 'C:/w/tools/text-filter.py'
$ninjaText = $ninjaText.Replace('| sed s/web_kit/webkit/ | sed s/WEBKIT_TYPE_KIT/WEBKIT_TYPE/ >', '| "' + $pythonExe + '" "' + $textFilter + '" "s/web_kit/webkit/" "s/WEBKIT_TYPE_KIT/WEBKIT_TYPE/" >')
$ninjaText = $ninjaText.Replace('| sed s/web_kit/webkit/ >', '| "' + $pythonExe + '" "' + $textFilter + '" "s/web_kit/webkit/" >')
$copyTree = 'C:/w/tools/copy-tree.ps1'
$lnPairs = @(
    @('C:/w/.tools/webkit-src/Source/JavaScriptCore/API/glib', 'C:/w/zig-out/webkit-linux6/JavaScriptCoreGLib/Headers/jsc'),
    @('C:/w/.tools/webkit-src/Source/JavaScriptCore/API/glib', 'C:/w/zig-out/webkit-linux6/DerivedSources/ForwardingHeaders/wpe-jsc/jsc'),
    @('C:/w/.tools/webkit-src/Source/WebKit/WebProcess/InjectedBundle/API/wpe', 'C:/w/zig-out/webkit-linux6/DerivedSources/ForwardingHeaders/wpe-web-process-extension/wpe'),
    @('C:/w/.tools/webkit-src/Source/WebKit/UIProcess/API/wpe', 'C:/w/zig-out/webkit-linux6/DerivedSources/ForwardingHeaders/wpe/wpe')
)
foreach ($pair in $lnPairs) {
    $ninjaText = $ninjaText.Replace("ln -n -s -f $($pair[0]) $($pair[1])", "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $copyTree $($pair[0]) $($pair[1])")
}
$nested = ((Join-Path $build 'JavaScriptCore\PrivateHeaders\JavaScriptCore').Replace('\','/'))
$ninjaText = $ninjaText.Replace("-I$nested ", '')
$nestedW = $nested.Replace('C:/git/csos', 'C:/w')
$ninjaText = $ninjaText.Replace("-I$nestedW ", '')
$webCoreNested = ((Join-Path $build 'WebCore\PrivateHeaders\WebCore').Replace('\','/'))
$webCoreNestedW = $webCoreNested.Replace('C:/git/csos', 'C:/w')
$webCorePrivateW = ((Join-Path $build 'WebCore\PrivateHeaders').Replace('\','/')).Replace('C:/git/csos', 'C:/w')
if (-not $ninjaText.Contains("-I$webCoreNested ") -and -not $ninjaText.Contains("-I$webCoreNestedW ")) {
    $ninjaText = $ninjaText.Replace("-I$webCorePrivate ", "-I$webCorePrivate -I$webCoreNested ")
    $ninjaText = $ninjaText.Replace("-I$webCorePrivateW ", "-I$webCorePrivateW -I$webCoreNestedW ")
}
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
$jscRemoteInclude = ((Join-Path $webkit 'Source\JavaScriptCore\inspector\remote').Replace('\','/'))
$soupInclude = ((Join-Path $repo '.tools\libsoup-src\libsoup').Replace('\','/'))
$soupServerInclude = ((Join-Path $repo '.tools\libsoup-src\libsoup\server').Replace('\','/'))
$soupGeneratedInclude = ((Join-Path $repo 'zig-out\libsoup-linux\libsoup').Replace('\','/'))
$badInspectorDir = ((Join-Path $build 'WebInspectorUI\DerivedSources\InspectorResources\WebInspectorUI').Replace('\','/'))
$intermediateInspectorDir = ((Join-Path $build 'WebInspectorUI\DerivedSources\InspectorResources').Replace('\','/'))
$goodInspectorDir = ((Join-Path $build 'WebInspectorUI').Replace('\','/'))
$ninjaText = $ninjaText.Replace("--sourcedir=$badInspectorDir", "--sourcedir=$goodInspectorDir")
$ninjaText = $ninjaText.Replace("--sourcedir=$intermediateInspectorDir", "--sourcedir=$goodInspectorDir")
$badInspectorDirW = $badInspectorDir.Replace('C:/git/csos', 'C:/w')
$intermediateInspectorDirW = $intermediateInspectorDir.Replace('C:/git/csos', 'C:/w')
$goodInspectorDirW = $goodInspectorDir.Replace('C:/git/csos', 'C:/w')
$ninjaText = $ninjaText.Replace("--sourcedir=$badInspectorDirW", "--sourcedir=$goodInspectorDirW")
$ninjaText = $ninjaText.Replace("--sourcedir=$intermediateInspectorDirW", "--sourcedir=$goodInspectorDirW")
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
$generatedResourceXml = Get-ChildItem $build -Recurse -File -Filter 'ModernMediaControlsGResourceBundle.xml' -ErrorAction SilentlyContinue
foreach ($resourceXml in $generatedResourceXml) {
    # glib-compile-resources delegates xml-stripblanks to xmllint.  The
    # cross sysroot has no host xmllint, and stripping whitespace is not
    # semantically required for WebKit's SVG assets, so avoid that host-only
    # helper in the generated manifest.
    $resourceText = [IO.File]::ReadAllText($resourceXml.FullName)
    $resourceUpdated = $resourceText.Replace(' preprocess="xml-stripblanks"', '')
    if ($resourceUpdated -ne $resourceText) {
        [IO.File]::WriteAllText($resourceXml.FullName, $resourceUpdated, [Text.UTF8Encoding]::new($false))
    }
}
$generatedSerializers = Get-ChildItem $build -Recurse -File -Filter 'GeneratedSerializers.h' -ErrorAction SilentlyContinue
foreach ($serializerHeader in $generatedSerializers) {
    $serializerText = [IO.File]::ReadAllText($serializerHeader.FullName)
    if (-not $serializerText.Contains('#include <WebCore/ScrollTypes.h>')) {
        $serializerText = $serializerText.Replace('#include <wtf/ArgumentCoder.h>', '#include <WebCore/ScrollTypes.h>' + [Environment]::NewLine + '#include <wtf/ArgumentCoder.h>')
        Write-TextRetry $serializerHeader.FullName $serializerText
    }
}
$generatedSerializerSources = Get-ChildItem $build -Recurse -File -Include 'GeneratedSerializers.cpp','SerializedTypeInfo.cpp','WebKitPlatformGeneratedSerializers.cpp' -ErrorAction SilentlyContinue
foreach ($serializerSource in $generatedSerializerSources) {
    $serializerSourceText = [IO.File]::ReadAllText($serializerSource.FullName)
    $serializerSourceUpdated = $serializerSourceText.Replace('#include "ResourceLoadInfo.h"', '#include "Shared/ResourceLoadInfo.h"')
    if ($serializerSourceUpdated -ne $serializerSourceText) {
        Write-TextRetry $serializerSource.FullName $serializerSourceUpdated
    }
}
# The nested WebCore private-header include directory contains a same-named
# header as WebKit's UIProcess class. Make this generated receiver explicit so
# it cannot bind to WebCore::VisitedLinkStore.
$visitedReceiver = Join-Path $build 'DerivedSources\WebKit\VisitedLinkStoreMessageReceiver.cpp'
if (Test-Path -LiteralPath $visitedReceiver) {
    $visitedText = [IO.File]::ReadAllText($visitedReceiver)
    $visitedUpdated = $visitedText.Replace('#include "VisitedLinkStore.h"', '#include "UIProcess/VisitedLinkStore.h"')
    if ($visitedUpdated -ne $visitedText) {
        Write-TextRetry $visitedReceiver $visitedUpdated
    }
}
# The extra WebCore private-header include directory contains its own
# ResourceLoadInfo.h.  Generated WebKit IPC receivers use the WebKit shared
# type, so make that include explicit instead of allowing include-order
# dependent resolution to leave WebKit::ResourceLoadInfo incomplete.
$generatedWebKitSources = Join-Path $build 'DerivedSources\WebKit'
if (Test-Path -LiteralPath $generatedWebKitSources) {
    Get-ChildItem $generatedWebKitSources -Recurse -File -Include '*.cpp','*.mm','*.h' | ForEach-Object {
        $sourceText = [IO.File]::ReadAllText($_.FullName)
        $sourceUpdated = $sourceText.Replace('#include "ResourceLoadInfo.h"', '#include "Shared/ResourceLoadInfo.h"')
        if ($sourceUpdated -ne $sourceText) {
            Write-TextRetry $_.FullName $sourceUpdated
        }
    }
}
foreach ($script in $generatedScripts) {
    $scriptText = [IO.File]::ReadAllText($script.FullName)
    # CMake materializes generator commands in standalone .bat files after
    # configure. Patch those files as well as build.ninja so Windows does not
    # try to resolve the Unix-only glib-mkenums launcher from PATH.
    $updatedScript = $scriptText.Replace('glib-mkenums ', ('"' + $pythonExe + '" "' + $glibMkenums + '" '))
    $updatedScript = $updatedScript.Replace($glibResources, ('"' + $pythonExe + '" "' + $glibResourcesWrapper + '"'))
    $updatedScript = $updatedScript.Replace($glibResourcesW, ('"' + $pythonExe + '" "' + $glibResourcesWrapper + '"'))
    $updatedScript = $updatedScript.Replace($glibResourcesWin, ('"' + $pythonExe + '" "' + $glibResourcesWrapper + '"'))
    $updatedScript = $updatedScript.Replace($glibResourcesWW, ('"' + $pythonExe + '" "' + $glibResourcesWrapper + '"'))
    # Regenerate serializers through the wrapper so generated headers retain
    # the WebCore ScrollTypes declaration required by this cross-build.
    $updatedScript = $updatedScript.Replace($serializerGenerator, $serializerWrapper)
    $updatedScript = $updatedScript.Replace('| sed s/web_kit/webkit/ | sed s/WEBKIT_TYPE_KIT/WEBKIT_TYPE/ >', '| "' + $pythonExe + '" "' + $textFilter + '" "s/web_kit/webkit/" "s/WEBKIT_TYPE_KIT/WEBKIT_TYPE/" >')
    $updatedScript = $updatedScript.Replace('| sed s/web_kit/webkit/ >', '| "' + $pythonExe + '" "' + $textFilter + '" "s/web_kit/webkit/" >')
    $updatedScript = $updatedScript.Replace(('"' + $zig + '" c++ -E'), ('"' + $wrapper + '"'))
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
if (-not $ninjaText.Contains("-I$jscRemoteInclude ")) {
    # RemoteInspectorServer.h includes RemoteInspector.h by basename.  The
    # generated JavaScriptCore private-header forwarding tree does not carry
    # the source inspector/remote directory in WebKit's target include list.
    # Keep the upstream directory explicit so GLib API compilation resolves
    # the canonical header instead of relying on platform-specific propagation.
    $ninjaText = $ninjaText.Replace('INCLUDES = ', "INCLUDES = -I$jscRemoteInclude ")
}
# CMake emits per-object response files that do not inherit the target-level
# include added above. Ensure every existing response file can resolve the
# basename include used by RemoteInspectorServer.h.
Get-ChildItem -LiteralPath $build -Filter '*.rsp' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rspText = [IO.File]::ReadAllText($_.FullName)
    if (-not $rspText.Contains("-I$jscRemoteInclude ")) {
        $rspText = "-I$jscRemoteInclude " + $rspText
        [IO.File]::WriteAllText($_.FullName, $rspText, [Text.UTF8Encoding]::new($false))
    }
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
    $serverWrapper = Join-Path (Join-Path $soupInstalled 'server') $_.Name
    $includeName = "libsoup/websocket/$($_.Name)"
    $text = "#pragma once`n#include <$includeName>`n"
    [IO.File]::WriteAllText($rootWrapper, $text, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($serverWrapper, $text, [Text.UTF8Encoding]::new($false))
}
$dependencySuffix = " $gmoduleLib $pcre2Lib $ffiLib"
Get-ChildItem $build -Recurse -File -Filter '*.rsp' -ErrorAction SilentlyContinue | ForEach-Object {
    $rspText = [IO.File]::ReadAllText($_.FullName)
    # Reconfigure regenerates response files with the nested JavaScriptCore
    # private-header directory. On Windows those copies duplicate source
    # definitions; keep only the canonical forwarding-header root. WebCore
    # needs its nested directory because HbUniquePtr.h is included by name.
    $rspText = $rspText.Replace("-I$nested ", '')
    $rspText = $rspText.Replace("-I$nestedW ", '')
    if (-not $rspText.Contains("-I$webCoreNested ") -and -not $rspText.Contains("-I$webCoreNestedW ")) {
        $rspText = $rspText.Replace("-I$webCorePrivate ", "-I$webCorePrivate -I$webCoreNested ")
        $rspText = $rspText.Replace("-I$webCorePrivateW ", "-I$webCorePrivateW -I$webCoreNestedW ")
    }
    $rspText = $rspText.Replace('-IC:/git/csos/zig-out/libsoup-linux/libsoup ', '').Replace('-IC:/w/zig-out/libsoup-linux/libsoup ', '')
    $rspText = $rspText.Replace('-IC:/w/.tools/libsoup-src/libsoup ', '').Replace('-IC:/w/.tools/libsoup-src/libsoup/server ', '')
    if (-not $rspText.Contains("-I$jscRemoteInclude ")) {
        $rspText = "-I$jscRemoteInclude " + $rspText
    }
    # WebKit's current WebCore sources use std::optional::transform, which is
    # a C++23 API.  Zig's libc++ intentionally hides it under C++20, so make
    # the generated response files match the language level expected by the
    # source instead of patching WebCore itself.
    $rspText = $rspText.Replace('-std=c++20', '-std=c++23')
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
# libjpeg-turbo's generated configuration headers are not installed in the
# shared sysroot, but jpeglib.h includes jconfig.h directly.
Copy-Item -Force (Join-Path $jpegBuildPath 'jconfig.h'), (Join-Path $jpegBuildPath 'jconfigint.h'), (Join-Path $jpegBuildPath 'jversion.h') $include
# libepoxy's public and generated GL headers are required by TextureMapperGL.
$epoxyInclude = Join-Path $include 'epoxy'
New-Item -ItemType Directory -Force -Path $epoxyInclude | Out-Null
Copy-Item -Force (Join-Path $epoxySourcePath 'include\epoxy\*.h') $epoxyInclude
Copy-Item -Force (Join-Path $epoxyBuildPath 'include\epoxy\*.h') $epoxyInclude
# Some Meson configurations disable EGL discovery and therefore omit
# libepoxy's generated EGL header even though WebCore includes epoxy/egl.h.
# Generate it directly from the bundled Khronos registry when absent.
$epoxyEglHeader = Join-Path $epoxyInclude 'egl_generated.h'
if (-not (Test-Path -LiteralPath $epoxyEglHeader)) {
    $epoxyGenerator = Join-Path $epoxySourcePath 'src\gen_dispatch.py'
    $epoxyRegistry = Join-Path $epoxySourcePath 'registry\egl.xml'
    & python $epoxyGenerator --no-source --header --outputdir $epoxyInclude $epoxyRegistry
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $epoxyEglHeader)) {
        throw 'Could not generate libepoxy EGL dispatch header'
    }
}
# The generated JS binding is omitted when video support is disabled, while
# WebCore's unified source list still contains its custom implementation.
# Guard that implementation to match the feature configuration.
$mediaCustom = Join-Path $webkit 'Source\WebCore\bindings\js\JSHTMLMediaElementCustom.cpp'
$mediaText = [IO.File]::ReadAllText($mediaCustom)
$mediaText = $mediaText.Replace('`n', [Environment]::NewLine)
if (-not $mediaText.Contains('#if ENABLE(VIDEO)')) {
    $nl = [Environment]::NewLine
    $mediaText = $mediaText.Replace('namespace WebCore {', "#if ENABLE(VIDEO)$nl`nnamespace WebCore {")
    $mediaText = $mediaText.Replace('} // namespace WebCore', "} // namespace WebCore$nl`n#endif")
    [IO.File]::WriteAllText($mediaCustom, $mediaText, [Text.UTF8Encoding]::new($false))
} else {
    [IO.File]::WriteAllText($mediaCustom, $mediaText, [Text.UTF8Encoding]::new($false))
}
# Zig 0.16's bundled libc++ does not yet provide the C++23
# std::optional::transform member used by current WebCore sources. Keep the
# source portable by spelling these two small transformations explicitly.
$intersection = Join-Path $webkit 'Source\WebCore\page\IntersectionObserver.cpp'
$intersectionText = [IO.File]::ReadAllText($intersection)
$nl = [Environment]::NewLine
$intersectionText = $intersectionText.Replace('[&] (const RenderElement* renderer) -> std::optional<LayoutRect> { return Ref<const Frame>(renderer->frame())->frameDocumentSecurityOrigin(); }', '[&] (const RenderElement* renderer) { return Ref<const Frame>(renderer->frame())->frameDocumentSecurityOrigin(); }')
$intersectionText = $intersectionText.Replace('[&] (const RenderElement* renderer) -> std::optional<LayoutRect> { return static_cast<const Frame*>(&renderer->frame()); }', '[&] (const RenderElement* renderer) { return static_cast<const Frame*>(&renderer->frame()); }')
$intersectionText = $intersectionText.Replace('        [&] (const RenderElement* renderer) {', '        [&] (const RenderElement* renderer) -> std::optional<LayoutRect> {')
$intersectionText = $intersectionText.Replace('            return visibleRects.transform([] (auto&& repaintRects) { return repaintRects.clippedOverflowRect; } );', "            if (!visibleRects)$nl                return std::nullopt;$nl            return std::make_optional(visibleRects->clippedOverflowRect);")
$intersectionText = $intersectionText -replace '(?m)(^\s*\[&\] \(const RenderElement\* renderer\) )-> std::optional<LayoutRect>( \{ return Ref<const Frame>\(renderer->frame\(\)\)->frameDocumentSecurityOrigin\(\); \},)', '$1$2'
$intersectionText = $intersectionText -replace '(?m)(^\s*\[&\] \(const RenderElement\* renderer\) )-> std::optional<LayoutRect>( \{ return static_cast<const Frame>\(&renderer->frame\(\)\); \},)', '$1$2'
$intersectionText = $intersectionText -replace '(?m)(\[&\] \(const RenderElement\* renderer\) )-> std::optional<LayoutRect>( \{ return static_cast<const Frame>\(&renderer->frame\(\)\); \},)', '$1$2'
$intersectionText = $intersectionText.Replace('        [&] (const RenderElement* renderer) -> std::optional<LayoutRect> { return static_cast<const Frame*>(&renderer->frame()); },', '        [&] (const RenderElement* renderer) { return static_cast<const Frame*>(&renderer->frame()); },')
[IO.File]::WriteAllText($intersection, $intersectionText, [Text.UTF8Encoding]::new($false))
$localFrameView = Join-Path $webkit 'Source\WebCore\page\LocalFrameView.cpp'
$localFrameText = [IO.File]::ReadAllText($localFrameView)
$localFrameText = $localFrameText.Replace('    return rects.transform([] (const auto& repaintRects) { return repaintRects.clippedOverflowRect; });', "    if (!rects)$nl        return std::nullopt;$nl    return std::make_optional(rects->clippedOverflowRect);")
[IO.File]::WriteAllText($localFrameView, $localFrameText, [Text.UTF8Encoding]::new($false))
# PlatformImage.h includes the Cairo smart-pointer declarations without the
# feature subdirectory in its include path. Provide the canonical forwarding
# wrapper expected by WebCore's generated/private headers.
$graphicsDir = Join-Path $webkit 'Source\WebCore\platform\graphics'
$cairoRefPtr = Join-Path $graphicsDir 'RefPtrCairo.h'
if (-not (Test-Path -LiteralPath $cairoRefPtr)) {
    $cairoWrapperText = '#pragma once' + $nl + '#include "cairo/RefPtrCairo.h"' + $nl
    [IO.File]::WriteAllText($cairoRefPtr, $cairoWrapperText, [Text.UTF8Encoding]::new($false))
}
$intRectWrapper = Join-Path $webkit 'Source\WebCore\IntRect.h'
if (-not (Test-Path -LiteralPath $intRectWrapper)) {
    $intRectWrapperText = '#pragma once' + $nl + '#include "platform/graphics/IntRect.h"' + $nl
    [IO.File]::WriteAllText($intRectWrapper, $intRectWrapperText, [Text.UTF8Encoding]::new($false))
}
# Accessibility ATSPI includes IntRect.h from its own directory; provide the
# local forwarding header required by WebKit's include search order.
$atspiIntRectWrapper = Join-Path $webkit 'Source\WebCore\accessibility\atspi\IntRect.h'
if (-not (Test-Path -LiteralPath $atspiIntRectWrapper)) {
    $atspiIntRectText = '#pragma once' + $nl + '#include "../../platform/graphics/IntRect.h"' + $nl
    [IO.File]::WriteAllText($atspiIntRectWrapper, $atspiIntRectText, [Text.UTF8Encoding]::new($false))
}
$doublePointWrapper = Join-Path $webkit 'Source\WebCore\platform\DoublePoint.h'
if (-not (Test-Path -LiteralPath $doublePointWrapper)) {
    $doublePointText = '#pragma once' + $nl + '#include "graphics/DoublePoint.h"' + $nl
    [IO.File]::WriteAllText($doublePointWrapper, $doublePointText, [Text.UTF8Encoding]::new($false))
}
$credentialSoupWrapper = Join-Path $webkit 'Source\WebCore\platform\network\CredentialSoup.h'
if (-not (Test-Path -LiteralPath $credentialSoupWrapper)) {
    $credentialSoupText = '#pragma once' + $nl + '#include "soup/CredentialSoup.h"' + $nl
    [IO.File]::WriteAllText($credentialSoupWrapper, $credentialSoupText, [Text.UTF8Encoding]::new($false))
}
$soupCredentialBaseWrapper = Join-Path $webkit 'Source\WebCore\platform\network\soup\CredentialBase.h'
if (-not (Test-Path -LiteralPath $soupCredentialBaseWrapper)) {
    $soupCredentialBaseText = '#pragma once' + $nl + '#include "../CredentialBase.h"' + $nl
    [IO.File]::WriteAllText($soupCredentialBaseWrapper, $soupCredentialBaseText, [Text.UTF8Encoding]::new($false))
}
$cairoGraphicsContextWrapper = Join-Path $webkit 'Source\WebCore\platform\graphics\cairo\GraphicsContext.h'
if (-not (Test-Path -LiteralPath $cairoGraphicsContextWrapper)) {
    $cairoGraphicsContextText = '#pragma once' + $nl + '#include "../GraphicsContext.h"' + $nl
    [IO.File]::WriteAllText($cairoGraphicsContextWrapper, $cairoGraphicsContextText, [Text.UTF8Encoding]::new($false))
}
$hbUniquePtrWrapper = Join-Path $webkit 'Source\WebCore\HbUniquePtr.h'
if (-not (Test-Path -LiteralPath $hbUniquePtrWrapper)) {
    $hbUniquePtrText = '#pragma once' + $nl + '#include "platform/graphics/harfbuzz/HbUniquePtr.h"' + $nl
    [IO.File]::WriteAllText($hbUniquePtrWrapper, $hbUniquePtrText, [Text.UTF8Encoding]::new($false))
}
Write-Output "WebKit cross build repaired: $build"
