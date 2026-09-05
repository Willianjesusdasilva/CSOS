$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$archive = Join-Path $workspace '.tools/glslang-16.5.0-windows-x86_64-release.zip'
$destination = Join-Path $workspace '.tools/glslang-16.5.0'
$executable = Join-Path $destination 'bin/glslang.exe'
$archiveHash = '06b71298b750268c127f2ee7ae0ef7525e2068120c6c8a3a08b2f58ca6f325ce'
$executableHash = 'e207976041258c1ccfb32902c2a3d543542c1a463c84bd2dd6ba0dca78ea3578'
New-Item -ItemType Directory -Force -Path (Join-Path $workspace '.tools') | Out-Null
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest 'https://github.com/KhronosGroup/glslang/releases/download/16.5.0/glslang-16.5.0-windows-x86_64-release.zip' -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $archiveHash) {
    throw 'glslang archive checksum mismatch; archive was not extracted.'
}
if (-not (Test-Path -LiteralPath $destination)) {
    Expand-Archive -LiteralPath $archive -DestinationPath $destination
}
if (-not (Test-Path -LiteralPath $executable) -or
    (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ne $executableHash) {
    throw 'glslang installation is incomplete or modified; existing files were preserved.'
}
& $executable --version
if ($LASTEXITCODE -ne 0) { throw 'glslang execution failed.' }
