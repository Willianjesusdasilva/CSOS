param(
    [string]$CsosEfi = (Join-Path $PSScriptRoot '..\zig-out\bin\BOOTX64.efi'),
    [string]$RecoveryKernel = (Join-Path $PSScriptRoot '..\zig-out\recovery\alpine-extract\vmlinuz-virt'),
    [string]$RecoveryInitramfs = (Join-Path $PSScriptRoot '..\zig-out\recovery\initramfs-recovery'),
    [string]$GrubEfi = (Join-Path $PSScriptRoot '..\zig-out\recovery\grubx64.efi.signed'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\zig-out\recovery-esp'),
    [ValidateSet('CSOS', 'Recovery')][string]$DefaultEntry = 'CSOS'
)

$ErrorActionPreference = 'Stop'
foreach ($path in @($CsosEfi, $RecoveryKernel, $RecoveryInitramfs, $GrubEfi)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Boot input not found: $path" }
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path (Join-Path $resolvedOutput 'EFI\BOOT') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $resolvedOutput 'EFI\CSOS') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $resolvedOutput 'boot') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $resolvedOutput 'boot\grub') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $resolvedOutput 'EFI\ubuntu') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $resolvedOutput 'EFI\debian') | Out-Null
Copy-Item -Force -LiteralPath $GrubEfi -Destination (Join-Path $resolvedOutput 'EFI\BOOT\BOOTX64.EFI')
Copy-Item -Force -LiteralPath $CsosEfi -Destination (Join-Path $resolvedOutput 'EFI\CSOS\BOOTX64.EFI')
Copy-Item -Force -LiteralPath $RecoveryKernel -Destination (Join-Path $resolvedOutput 'boot\vmlinuz-virt')
Copy-Item -Force -LiteralPath $RecoveryInitramfs -Destination (Join-Path $resolvedOutput 'boot\initramfs-recovery')

$defaultIndex = [int]($DefaultEntry -eq 'Recovery')
$config = @"
set timeout=5
set default=$defaultIndex
serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial
insmod chain
insmod linux
insmod fat

menuentry "CSOS" {
    chainloader /EFI/CSOS/BOOTX64.EFI
    boot
}

menuentry "CSOS Recovery" {
    linux /boot/vmlinuz-virt console=ttyS0 rdinit=/init-recovery
    initrd /boot/initramfs-recovery
}
"@
$config | Set-Content -Encoding ASCII -LiteralPath (Join-Path $resolvedOutput 'grub.cfg')
$config | Set-Content -Encoding ASCII -LiteralPath (Join-Path $resolvedOutput 'boot\grub\grub.cfg')
$config | Set-Content -Encoding ASCII -LiteralPath (Join-Path $resolvedOutput 'EFI\ubuntu\grub.cfg')
$config | Set-Content -Encoding ASCII -LiteralPath (Join-Path $resolvedOutput 'EFI\debian\grub.cfg')

$manifest = @(
    'CSOS persistent UEFI boot menu'
    'default=CSOS'
    'recovery=CSOS Recovery'
    "csos_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $resolvedOutput 'EFI\CSOS\BOOTX64.EFI')).Hash)"
    "recovery_kernel_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $resolvedOutput 'boot\vmlinuz-virt')).Hash)"
    "recovery_initramfs_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $resolvedOutput 'boot\initramfs-recovery')).Hash)"
)
$manifest | Set-Content -Encoding ASCII -LiteralPath (Join-Path $resolvedOutput 'BOOT-MANIFEST.txt')
Write-Output "Recovery boot ESP staged at $resolvedOutput"
Write-Output 'Entries: CSOS (default), CSOS Recovery'
