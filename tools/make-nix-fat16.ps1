param(
    [Parameter(Mandatory = $true)][string]$ClosureArchive,
    [string]$Output = (Join-Path $PSScriptRoot '..\zig-out\nix.img'),
    [int]$SizeMiB = 256
)

$ErrorActionPreference = 'Stop'
$archive = (Resolve-Path -LiteralPath $ClosureArchive).Path
$outputPath = [IO.Path]::GetFullPath($Output)
if ($SizeMiB -lt 128 -or $SizeMiB -gt 2048) { throw 'SizeMiB must be between 128 and 2048.' }
function To-Wsl([string]$value) {
    return "/mnt/" + $value.Substring(0, 1).ToLowerInvariant() + $value.Substring(2).Replace('\', '/')
}
$archiveWsl = To-Wsl $archive
$outputWsl = To-Wsl $outputPath
$command = "set -eu; root=/tmp/csos-nix-fat-root; rm -rf `$root; mkdir -p `$root; tar -xf '$archiveWsl' -C `$root; mkdir -p '`$(dirname '$outputWsl')'; truncate -s ${SizeMiB}M '$outputWsl'; mkfs.fat -F 16 -S 512 -s 16 -n CSOSNIX '$outputWsl' >/dev/null; export MTOOLS_SKIP_CHECK=1; mmd -i '$outputWsl' ::/nix ::/nix/bin ::/nix/lib; mcopy -s -i '$outputWsl' `$root/usr/bin/nix ::/nix/bin/; mcopy -s -i '$outputWsl' `$root/usr/lib/* ::/nix/lib/; mdir -i '$outputWsl' ::/nix/bin; mdir -i '$outputWsl' ::/nix/lib | tail -n 1"
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
& wsl.exe -d Ubuntu -- bash -lc "echo $encoded | base64 -d | bash"
if ($LASTEXITCODE -ne 0) { throw "Nix FAT image creation failed ($LASTEXITCODE)" }
Write-Output "Nix FAT image created: $outputPath"
