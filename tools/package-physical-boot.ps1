param(
    [string]$EfiBinary = (Join-Path $PSScriptRoot '..\zig-out\bin\BOOTX64.efi'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\zig-out\physical-boot')
)

$ErrorActionPreference = 'Stop'
$efi = (Resolve-Path -LiteralPath $EfiBinary).Path
$bytes = [IO.File]::ReadAllBytes($efi)
if ($bytes.Length -lt 0x80 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'Input is not a DOS/PE image.' }
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
if ($peOffset -lt 0 -or $peOffset + 96 -ge $bytes.Length -or $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) { throw 'Input lacks a valid PE signature.' }
$peMagic = [BitConverter]::ToUInt16($bytes, $peOffset + 24)
$subsystem = [BitConverter]::ToUInt16($bytes, $peOffset + 92)
if ($peMagic -ne 0x20B -or $subsystem -ne 10) { throw 'Input is not a PE32+ EFI application.' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$destination = Join-Path $OutputDirectory 'BOOTX64.EFI'
Copy-Item -Force -LiteralPath $efi -Destination $destination
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
@(
    'CSOS physical UEFI boot package'
    "file=BOOTX64.EFI"
    "bytes=$((Get-Item -LiteralPath $destination).Length)"
    "sha256=$hash"
) | Set-Content -Encoding ASCII -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt')
Write-Output "Packaged $destination"
Write-Output "SHA256 $hash"
