param(
    [string]$Root = (Join-Path $PSScriptRoot '..\zig-out\persistence-layout-test')
)

$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($Root)
if ([string]::IsNullOrWhiteSpace($rootPath) -or $rootPath -eq [IO.Path]::GetPathRoot($rootPath)) {
    throw 'Refusing to test a filesystem root; pass a dedicated test directory.'
}

if (Test-Path -LiteralPath $rootPath) {
    Remove-Item -LiteralPath $rootPath -Recurse -Force
}
$system = Join-Path $rootPath 'system'
$data = Join-Path $rootPath 'data'
$homePath = Join-Path $rootPath 'home'
$nix = Join-Path $rootPath 'nix'
New-Item -ItemType Directory -Force -Path (Join-Path $system 'config\defaults'), (Join-Path $data 'config'), $homePath, $nix | Out-Null

Push-Location $system
try {
    & git init --quiet
    Set-Content -LiteralPath (Join-Path $system 'config\defaults\README.md') -Value 'versioned defaults'
    & git add .
    & git -c user.email=csos-test@example.invalid -c user.name=csos-test commit --quiet -m initial
    Set-Content -LiteralPath (Join-Path $data 'config\hardware.csc') -Value 'machine signature=fixture'
    & git reset --hard --quiet HEAD
} finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath (Join-Path $data 'config\hardware.csc'))) {
    throw 'Persistent data was lost during the system checkout reset.'
}
if (-not (Test-Path -LiteralPath (Join-Path $system 'config\defaults\README.md'))) {
    throw 'Versioned defaults were not restored.'
}
Write-Output "CSOS persistence layout PASS: /system reset preserved /data, /home, and /nix"
