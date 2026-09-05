param([switch]$Wipe, [switch]$Reconfigure)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = Join-Path $workspace '.tools/mesa-src'
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne '9311c93dbef6b87a30bc282c3683efefc5f26f77') {
    throw 'The RADV build requires Mesa revision 9311c93dbef6b87a30bc282c3683efefc5f26f77.'
}
$changes = & git -C $source status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Use an unmodified Mesa source checkout.' }
if ($Wipe -and $Reconfigure) { throw 'Choose either -Wipe or -Reconfigure.' }
$environmentScripts = Join-Path $workspace '.tools/mesa-build-env/Scripts'
$meson = Join-Path $environmentScripts 'meson.exe'
if (-not (Test-Path -LiteralPath $meson)) {
    throw 'Prepare .tools/mesa-build-env using tools/mesa-build-requirements.txt first.'
}
$stagingPkgConfig = Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib/pkgconfig'
foreach ($package in @('libdrm.pc', 'libdrm_amdgpu.pc', 'zlib.pc')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stagingPkgConfig $package))) {
        throw "Missing Linux target dependency $package; run the corresponding build script first."
    }
}
$cpuModel = Join-Path $workspace 'zig-out/mesa-sysroot/usr/lib/compiler-rt-cpu-model.o'
if (-not (Test-Path -LiteralPath $cpuModel)) {
    throw 'Missing compiler-rt CPU model runtime; run tools/build-compiler-rt-cpu-model.ps1 first.'
}
$previousPath = $env:PATH
$previousPkgPath = $env:PKG_CONFIG_PATH
$previousSysroot = $env:PKG_CONFIG_SYSROOT_DIR
Push-Location $workspace
try {
    $env:PATH = "$environmentScripts;$previousPath"
    $env:PKG_CONFIG_PATH = ''
    $env:PKG_CONFIG_SYSROOT_DIR = ''
    # Headless RADV bring-up profile, not the final display/WSI configuration.
    [string[]]$setupMode = if ($Wipe) { '--wipe' } elseif ($Reconfigure) { '--reconfigure' } else { @() }
    & $meson setup zig-out/mesa-radv .tools/mesa-src @setupMode `
        --cross-file tools/mesa-linux-cross.ini --native-file tools/mesa-windows-native.ini `
        --wrap-mode=nofallback --libdir=lib -Dauto_features=disabled -Dvulkan-drivers=amd `
        '-Dgallium-drivers=[]' '-Dplatforms=[]' -Dopengl=false -Dglx=disabled `
        -Degl=disabled -Dgbm=disabled -Dllvm=disabled -Dshader-cache=disabled
    if ($LASTEXITCODE -ne 0) { throw 'RADV configuration failed; inspect zig-out/mesa-radv/meson-logs/meson-log.txt.' }
} finally {
    $env:PATH = $previousPath
    $env:PKG_CONFIG_PATH = $previousPkgPath
    $env:PKG_CONFIG_SYSROOT_DIR = $previousSysroot
    Pop-Location
}
