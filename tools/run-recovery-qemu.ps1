param(
    [string]$Disk = (Join-Path $PSScriptRoot '..\zig-out\nvme.img'),
    [string]$Kernel = (Join-Path $PSScriptRoot '..\zig-out\recovery\alpine-extract\vmlinuz-virt'),
    [string]$Initramfs = (Join-Path $PSScriptRoot '..\zig-out\recovery\alpine-extract\initramfs-virt'),
    [string]$Append = 'console=ttyS0 init=/bin/sh'
)

$ErrorActionPreference = 'Stop'
$qemu = Join-Path $env:ProgramFiles 'qemu\qemu-system-x86_64.exe'
foreach ($path in @($qemu, $Disk, $Kernel, $Initramfs)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Recovery input not found: $path" }
}

& $qemu -machine q35 -m 1024 -kernel (Resolve-Path -LiteralPath $Kernel).Path `
    -initrd (Resolve-Path -LiteralPath $Initramfs).Path -append $Append `
    -drive "file=$((Resolve-Path -LiteralPath $Disk).Path),format=raw,if=virtio" `
    -display none -serial stdio -no-reboot
