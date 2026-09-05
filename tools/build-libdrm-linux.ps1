$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = Join-Path $workspace '.tools/libdrm-src'
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne '773536b1e5dde694dd743815528aff8bb2cf2cc3') {
    throw 'The Linux library build requires the pinned libdrm revision.'
}
$changes = & git -C $source status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Use an unmodified libdrm checkout.' }
$environmentScripts = Join-Path $workspace '.tools/mesa-build-env/Scripts'
$meson = Join-Path $environmentScripts 'meson.exe'
$previousPath = $env:PATH
$previousPkgPath = $env:PKG_CONFIG_PATH
$previousSysroot = $env:PKG_CONFIG_SYSROOT_DIR
Push-Location $workspace
try {
    $env:PATH = "$environmentScripts;$previousPath"
    $env:PKG_CONFIG_PATH = ''
    $env:PKG_CONFIG_SYSROOT_DIR = ''
    & $meson setup zig-out/libdrm-linux .tools/libdrm-src `
        --cross-file tools/mesa-linux-cross.ini --native-file tools/mesa-windows-native.ini `
        "--prefix=$workspace/zig-out/mesa-sysroot/usr" --libdir=lib `
        -Dauto_features=disabled -Damdgpu=enabled -Dtests=false -Dudev=false --wrap-mode=nofallback
    if ($LASTEXITCODE -ne 0) { throw 'libdrm Linux configuration failed.' }
    & $meson compile -C zig-out/libdrm-linux -j 4
    if ($LASTEXITCODE -ne 0) { throw 'libdrm Linux compilation failed.' }
    & $meson test -C zig-out/libdrm-linux --no-rebuild --print-errorlogs
    if ($LASTEXITCODE -ne 0) { throw 'libdrm exported-symbol checks failed.' }
    $libraryDirectory = Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib'
    $libraries = @(
        @{ File = 'libdrm.so.2.134.0'; Aliases = @('libdrm.so', 'libdrm.so.2') },
        @{ File = 'libdrm_amdgpu.so.1.134.0'; Aliases = @('libdrm_amdgpu.so', 'libdrm_amdgpu.so.1') }
    )
    # Remove only verified generated copies before Meson attempts symlinks.
    foreach ($library in $libraries) {
        foreach ($alias in $library.Aliases) {
            $aliasPath = Join-Path $libraryDirectory $alias
            if ((Test-Path -LiteralPath $aliasPath) -and -not (Get-Item -LiteralPath $aliasPath).LinkType) {
                $originalPath = Join-Path $libraryDirectory $library.File
                if ((Get-FileHash -LiteralPath $aliasPath).Hash -ne (Get-FileHash -LiteralPath $originalPath).Hash) {
                    throw "Preserving modified library alias: $aliasPath"
                }
                Remove-Item -LiteralPath $aliasPath
            }
        }
    }
    & $meson install -C zig-out/libdrm-linux --no-rebuild
    if ($LASTEXITCODE -ne 0) { throw 'libdrm Linux staging failed.' }
    # Meson skips symlinks when this Windows session cannot create them.
    # Stage byte-identical aliases needed by -l and by the ELF SONAMEs.
    foreach ($library in $libraries) {
        foreach ($alias in $library.Aliases) {
            $aliasPath = Join-Path $libraryDirectory $alias
            if (Test-Path -LiteralPath $aliasPath) {
                if ((Get-Item -LiteralPath $aliasPath).LinkType) { continue }
            }
            Copy-Item -LiteralPath (Join-Path $libraryDirectory $library.File) -Destination $aliasPath -Force
        }
    }
} finally {
    $env:PATH = $previousPath
    $env:PKG_CONFIG_PATH = $previousPkgPath
    $env:PKG_CONFIG_SYSROOT_DIR = $previousSysroot
    Pop-Location
}
