param(
    [string]$Disk = (Join-Path $PSScriptRoot '..\zig-out\nvme.img'),
    [string]$RecoveryInitramfs = (Join-Path $PSScriptRoot '..\zig-out\recovery\initramfs-recovery'),
    [string]$GrubEfi = (Join-Path $PSScriptRoot '..\zig-out\recovery\grubx64.efi.signed'),
    [string]$CsosEfi = (Join-Path $PSScriptRoot '..\zig-out\bin\BOOTX64.efi'),
    [ValidateRange(5, 120)][int]$TimeoutSeconds = 30
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$id = [Guid]::NewGuid().ToString('N')
$flowDisk = Join-Path $repo "zig-out\recovery\p2-flow-$id.img"
$esp = Join-Path $repo "zig-out\recovery\p2-esp-$id"
Copy-Item -Force -LiteralPath $Disk -Destination $flowDisk
try {
    foreach ($mode in @('recovery-seed-previous', 'recovery-reset-previous')) {
        $expect = if ($mode -eq 'recovery-seed-previous') { 'RECOVERY_GIT_STATUS_OK' } else { 'RECOVERY_GIT_RESTORED' }
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-recovery-qemu.ps1') `
            -Disk $flowDisk -Initramfs $RecoveryInitramfs `
            -Append "console=ttyS0 rdinit=/init-recovery $mode" `
            -SmokeTestSeconds $TimeoutSeconds -ExpectSerial $expect
        if ($LASTEXITCODE -ne 0) { throw "Recovery phase failed: $mode" }
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'package-recovery-boot.ps1') `
        -CsosEfi $CsosEfi -RecoveryInitramfs $RecoveryInitramfs -GrubEfi $GrubEfi `
        -OutputDirectory $esp -DefaultEntry CSOS
    $qemu = Join-Path $env:ProgramFiles 'qemu\qemu-system-x86_64.exe'
    $ovmf = Join-Path $env:ProgramFiles 'qemu\share\edk2-x86_64-code.fd'
    $serial = Join-Path $repo "zig-out\recovery\p2-csos-$id.serial.log"
    $stderr = Join-Path $repo "zig-out\recovery\p2-csos-$id.stderr.log"
    $args = @('-machine','q35','-m','1024M','-drive',"if=pflash,format=raw,readonly=on,file=$([IO.Path]::GetFullPath($ovmf))",'-drive',"format=raw,file=fat:rw:$([IO.Path]::GetFullPath($esp))",'-drive',"if=none,id=nvme0,format=raw,file=$([IO.Path]::GetFullPath($flowDisk))",'-device','nvme,drive=nvme0,serial=CSOS0001','-device','qemu-xhci,id=xhci','-device','usb-kbd,bus=xhci.0','-device','usb-mouse,bus=xhci.0','-netdev','user,id=net0','-device','e1000e,netdev=net0','-display','none','-serial',"file:$([IO.Path]::GetFullPath($serial))",'-no-reboot')
    $quoted = $args | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }
    $p = Start-Process -FilePath $qemu -ArgumentList $quoted -PassThru -WindowStyle Hidden -RedirectStandardError $stderr
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $passed = $false
        while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $text = if (Test-Path -LiteralPath $serial) { Get-Content -Raw $serial } else { '' }
            if ($null -eq $text) { $text = '' }
            if ($text.Contains('CSOS graphical session ready')) { $passed = $true; break }
            if ($p.HasExited) { break }
            Start-Sleep -Milliseconds 200
        }
        if (-not $passed) { throw "CSOS boot marker missing: $serial" }
        Write-Output 'P2 recovery flow passed: Recovery seed -> Git restore -> CSOS reboot.'
        Write-Output "CSOS serial log: $serial"
    } finally { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $p.WaitForExit(5000) | Out-Null } }
} finally {
    if (Test-Path -LiteralPath $flowDisk) { Remove-Item -LiteralPath $flowDisk -Force -ErrorAction SilentlyContinue }
}
