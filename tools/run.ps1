param(
    [Parameter(Mandatory = $true)][string]$EfiBinary,
    [Parameter(Mandatory = $true)][string]$SharedLibrary,
    [Parameter(Mandatory = $true)][string]$ExtraLibrary,
    [string]$GpuFirmware,
    [switch]$UsbAudio,
    [switch]$ResetDisk,
    [string]$AudioBackend = 'none'
)

$qemu = Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue
if (-not $qemu) {
    $installedQemu = "$env:ProgramFiles\qemu\qemu-system-x86_64.exe"
    if (Test-Path -LiteralPath $installedQemu) {
        $qemu = Get-Item -LiteralPath $installedQemu
    }
}
if (-not $qemu) {
    throw 'qemu-system-x86_64 is required for zig build run'
}

$ovmf = @(
    "$env:ProgramFiles\qemu\share\edk2-x86_64-code.fd",
    "$env:ProgramFiles\qemu\share\edk2-x86_64-secure-code.fd"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $ovmf) {
    throw 'OVMF firmware was not found in the QEMU installation'
}

$esp = Join-Path $PSScriptRoot '..\zig-out\esp'
$bootDir = Join-Path $esp 'EFI\BOOT'
New-Item -ItemType Directory -Force -Path $bootDir | Out-Null
Copy-Item -Force -LiteralPath $EfiBinary -Destination (Join-Path $bootDir 'BOOTX64.EFI')
$localOvmf = Join-Path $PSScriptRoot '..\zig-out\OVMF_CODE.fd'
Copy-Item -Force -LiteralPath $ovmf -Destination $localOvmf
$nvmeDisk = Join-Path $PSScriptRoot '..\zig-out\nvme.img'
if ($ResetDisk -or $GpuFirmware -or -not (Test-Path -LiteralPath $nvmeDisk)) {
    & (Join-Path $PSScriptRoot 'make-fat16.ps1') -Path $nvmeDisk -SharedLibrary $SharedLibrary -ExtraLibrary $ExtraLibrary -GpuFirmware $GpuFirmware
}

$audioArguments = @()
if ($UsbAudio) {
    $audioArguments += '-audiodev'
    $audioArguments += "driver=$AudioBackend,id=audio0"
    $audioArguments += '-device'
    $audioArguments += 'usb-audio,bus=xhci.0,audiodev=audio0'
}

& $qemu.FullName -machine q35 -smp 4 -m 256M -drive "if=pflash,format=raw,readonly=on,file=$localOvmf" -drive "format=raw,file=fat:rw:$esp" -drive "if=none,id=nvme0,format=raw,file=$nvmeDisk" -device "nvme,drive=nvme0,serial=CSOS0001" -device "qemu-xhci,id=xhci" -device "usb-kbd,bus=xhci.0" -device "usb-mouse,bus=xhci.0" @audioArguments -netdev "user,id=net0" -device "e1000e,netdev=net0" -monitor "tcp:127.0.0.1:4444,server=on,wait=off" -serial stdio -no-reboot
exit $LASTEXITCODE
