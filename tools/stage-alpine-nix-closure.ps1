param(
    [Parameter(Mandatory = $true)][string]$ApkStatic,
    [string]$OutputArchive = (Join-Path $PSScriptRoot '..\zig-out\alpine-nix-closure.tar')
)

$ErrorActionPreference = 'Stop'
$apk = (Resolve-Path -LiteralPath $ApkStatic).Path
$archive = [IO.Path]::GetFullPath($OutputArchive)
function To-Wsl([string]$value) {
    $drive = $value.Substring(0, 1).ToLowerInvariant()
    return "/mnt/$drive" + $value.Substring(2).Replace('\', '/')
}
$apkWsl = To-Wsl $apk
$archiveWsl = To-Wsl $archive
$command = "set -eu; root=/tmp/csos-nix-closure; rm -rf `$root; mkdir -p `$root/etc/apk; printf '%s\n' https://dl-cdn.alpinelinux.org/alpine/edge/main https://dl-cdn.alpinelinux.org/alpine/edge/community > `$root/etc/apk/repositories; $apkWsl --usermode --root `$root --initdb --no-cache --allow-untrusted add nix; tar -C `$root -cf $archiveWsl ."
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
& wsl.exe -d Ubuntu -- bash -lc "echo $encoded | base64 -d | bash"
if ($LASTEXITCODE -ne 0) { throw "Alpine Nix closure staging failed ($LASTEXITCODE)" }
Write-Output "Alpine Nix closure staged: $archive"
