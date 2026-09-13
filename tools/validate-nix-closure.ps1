param(
    [Parameter(Mandatory = $true)][string]$Archive,
    [int]$FatBytes = 256MB,
    [int]$RootEntries = 512
)

$ErrorActionPreference = 'Stop'
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$archiveWsl = "/mnt/" + $archivePath.Substring(0, 1).ToLowerInvariant() + $archivePath.Substring(2).Replace('\', '/')
$listing = @(wsl.exe -d Ubuntu -- bash -lc "tar -tvf '$archiveWsl'")
if ($LASTEXITCODE -ne 0) { throw 'Could not read Alpine Nix closure archive.' }
$entries = @($listing | Where-Object { $_ -match '\s[^\s]+$' })
$links = @($listing | Where-Object { $_ -match '^l' })
$regular = @($listing | Where-Object { $_ -match '^-' })
$bytes = [int64]0
foreach ($line in $regular) {
    if ($line -match '^\S+\s+\S+\s+\S+\s+\S+\s+(\d+)\s+') { $bytes += [int64]$Matches[1] }
}
if ($entries.Count -gt $RootEntries) { throw "Closure has $($entries.Count) entries; FAT root allows $RootEntries." }
if ($bytes -gt $FatBytes) { throw "Closure has $bytes bytes; FAT image allows $FatBytes." }
Write-Output "Nix closure FAT validation: PASS ($($entries.Count) entries, $bytes bytes, $($links.Count) symlinks)"
if ($links.Count -gt 0) { Write-Output 'Symlinks must be materialized or represented by VFS aliases during import.' }
