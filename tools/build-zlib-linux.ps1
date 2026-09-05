$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = Join-Path $workspace '.tools/zlib-src'
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne '51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf') {
    throw 'The Linux zlib build requires upstream zlib 1.3.1 at the pinned revision.'
}
$changes = & git -C $source status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Use an unmodified zlib checkout.' }
$cmake = Join-Path $workspace '.tools/mesa-build-env/Scripts/cmake.exe'
if (-not (Test-Path -LiteralPath $cmake)) {
    throw 'Prepare .tools/mesa-build-env using tools/mesa-build-requirements.txt first.'
}
$workingSource = Join-Path $workspace 'zig-out/zlib-source'
$build = Join-Path $workspace 'zig-out/zlib-linux'
$staging = Join-Path $workspace 'zig-out/mesa-sysroot/usr'
if (-not (Test-Path -LiteralPath $workingSource)) {
    New-Item -ItemType Directory -Path $workingSource | Out-Null
    Get-ChildItem -LiteralPath $source -Force |
        Where-Object Name -ne '.git' |
        Copy-Item -Destination $workingSource -Recurse
}
# CMake's zlib project renames zconf.h in its source directory. It therefore
# operates on the generated working copy, never on the pinned checkout.
& $cmake -S $workingSource -B $build -G Ninja `
    "-DCMAKE_TOOLCHAIN_FILE=$workspace/tools/zig-linux-toolchain.cmake" `
    "-DCMAKE_INSTALL_PREFIX=$staging" `
    "-DINSTALL_PKGCONFIG_DIR=$staging/lib/pkgconfig" `
    -DZLIB_BUILD_EXAMPLES=OFF -DCMAKE_BUILD_TYPE=Release
if ($LASTEXITCODE -ne 0) { throw 'zlib Linux configuration failed.' }
& $cmake --build $build --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'zlib Linux compilation failed.' }
& $cmake --install $build
if ($LASTEXITCODE -ne 0) { throw 'zlib Linux staging failed.' }
$library = Join-Path $staging 'lib/libz.so.1.3.1'
if (-not (Test-Path -LiteralPath $library)) { throw 'Installed zlib ELF is missing.' }
$magic = [System.IO.File]::ReadAllBytes($library)[0..3]
if (-not ($magic[0] -eq 0x7f -and $magic[1] -eq 0x45 -and $magic[2] -eq 0x4c -and $magic[3] -eq 0x46)) {
    throw 'Installed zlib is not an ELF file.'
}
