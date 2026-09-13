param(
    [string]$CsosEfi = (Join-Path $PSScriptRoot '..\zig-out\bin\BOOTX64.efi'),
    [string]$GrubEfi = (Join-Path $PSScriptRoot '..\zig-out\recovery\grubx64.efi.signed'),
    [string]$RecoveryKernel = (Join-Path $PSScriptRoot '..\zig-out\recovery\alpine-extract\vmlinuz-virt'),
    [string]$RecoveryInitramfs = (Join-Path $PSScriptRoot '..\zig-out\recovery\initramfs-recovery'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\zig-out\bare-metal-install')
)
$ErrorActionPreference = 'Stop'
foreach ($path in @($CsosEfi, $GrubEfi, $RecoveryKernel, $RecoveryInitramfs)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Install input not found: $path" }
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $output | Out-Null
$esp = Join-Path $output 'EFI-system-partition'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'package-recovery-boot.ps1') `
    -CsosEfi $CsosEfi -GrubEfi $GrubEfi -RecoveryKernel $RecoveryKernel `
    -RecoveryInitramfs $RecoveryInitramfs -OutputDirectory $esp -DefaultEntry CSOS
if ($LASTEXITCODE -ne 0) { throw 'UEFI boot package creation failed.' }
@(
    'CSOS bare-metal installation staging package'
    'The staged ESP is the only partition written by this script.'
    'Copy the ESP contents to the target disk EFI System Partition.'
    'Create a CSOS data volume and populate it with the reproducible CSOS FAT image.'
    'Keep /data, /home and /nix outside the Git checkout.'
    "csos_efi_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $esp 'EFI\CSOS\BOOTX64.EFI')).Hash)"
    "grub_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $esp 'EFI\BOOT\BOOTX64.EFI')).Hash)"
    "recovery_initramfs_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $esp 'boot\initramfs-recovery')).Hash)"
) | Set-Content -Encoding ASCII -LiteralPath (Join-Path $output 'INSTALL-MANIFEST.txt')
Write-Output "Bare-metal install staging ready: $output"
Write-Output 'No physical disk was modified.'
