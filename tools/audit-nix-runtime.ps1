param(
    [string]$RuntimeDirectory = (Join-Path $PSScriptRoot '..\zig-out\nix-runtime'),
    [string]$WslDistribution = 'Ubuntu'
)

$ErrorActionPreference = 'Stop'
$runtime = [IO.Path]::GetFullPath((Join-Path $RuntimeDirectory 'nix'))
$binary = Join-Path $runtime 'bin\nix'
$loader = Join-Path $runtime 'lib\ld-musl-x86_64.so.1'
$manifest = Join-Path ([IO.Path]::GetFullPath($RuntimeDirectory)) 'MANIFEST.sha256'
foreach ($path in @($binary, $loader, $manifest)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Nix runtime artifact not found: $path" }
}

$linuxRuntime = (wsl.exe -d $WslDistribution -- wslpath -a ($runtime -replace '\\','/') 2>$null).Trim()
if (-not $linuxRuntime) { throw "Could not convert runtime path for WSL distribution '$WslDistribution'." }
$linuxRoot = $linuxRuntime -replace '/bin$',''
$command = "cd '$linuxRoot' && ./lib/ld-musl-x86_64.so.1 --library-path ./lib ./bin/nix --version"
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$output = @(wsl.exe -d $WslDistribution -- bash -lc $command 2>&1 | ForEach-Object { $_.ToString() })
$runtimeExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
$missing = @($output | ForEach-Object {
    if ($_ -match 'Error loading shared library ([^: ]+)') { $Matches[1] }
} | Sort-Object -Unique)
if ($missing.Count -gt 0) {
    Write-Output 'Nix runtime dependency audit: INCOMPLETE'
    Write-Output ('Missing shared libraries: ' + ($missing -join ', '))
    exit 2
}
if ($runtimeExitCode -ne 0) {
    Write-Output 'Nix runtime dependency audit: ELF startup failed'
    Write-Output ("Exit code: $runtimeExitCode")
    Write-Output ($output -join "`n")
    exit 3
}
if (($output -join "`n") -notmatch 'nix \(Nix\)') {
    Write-Output ($output -join "`n")
    throw 'Nix runtime did not report its version.'
}
Write-Output 'Nix runtime dependency audit: PASS'
