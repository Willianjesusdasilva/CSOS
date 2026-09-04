param(
    [Parameter(Mandatory = $true)][string]$EfiBinary,
    [Parameter(Mandatory = $true)][string]$SharedLibrary,
    [Parameter(Mandatory = $true)][string]$ExtraLibrary,
    [string]$GpuFirmware,
    [switch]$UsbAudio,
    [switch]$ResetDisk,
    [string]$AudioBackend = 'none',
    [ValidateRange(0, 300)][int]$SmokeTestSeconds = 0,
    [string]$ExpectSerial = 'CSOS M14 userspace DRM core ready'
)

$ErrorActionPreference = 'Stop'

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

$qemuArguments = @(
    '-machine', 'q35', '-smp', '4', '-m', '256M',
    '-drive', "if=pflash,format=raw,readonly=on,file=$localOvmf",
    '-drive', "format=raw,file=fat:rw:$esp",
    '-drive', "if=none,id=nvme0,format=raw,file=$nvmeDisk",
    '-device', 'nvme,drive=nvme0,serial=CSOS0001',
    '-device', 'qemu-xhci,id=xhci', '-device', 'usb-kbd,bus=xhci.0',
    '-device', 'usb-mouse,bus=xhci.0'
) + $audioArguments + @('-netdev', 'user,id=net0', '-device', 'e1000e,netdev=net0', '-no-reboot')

if ($SmokeTestSeconds -gt 0) {
    if ([string]::IsNullOrWhiteSpace($ExpectSerial)) { throw 'ExpectSerial must not be empty' }
    $runId = [Guid]::NewGuid().ToString('N')
    $serialLog = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\zig-out\smoke-$runId.serial.log"))
    $errorLog = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\zig-out\smoke-$runId.stderr.log"))
    $qemuArguments += @('-display', 'none', '-monitor', 'none', '-serial', "file:$serialLog")
    # Start-Process joins ArgumentList into a Windows command line. Quote each
    # argument explicitly so installation/workspace paths with spaces survive.
    $quotedArguments = $qemuArguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
    $testProcess = $null
    $testResult = 124
    try {
        $testProcess = Start-Process -FilePath $qemu.FullName -ArgumentList $quotedArguments -PassThru -WindowStyle Hidden -RedirectStandardError $errorLog
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.Elapsed.TotalSeconds -lt $SmokeTestSeconds) {
            $serialText = ''
            if (Test-Path -LiteralPath $serialLog) {
                $stream = [IO.File]::Open($serialLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                $reader = New-Object IO.StreamReader($stream)
                try { $serialText = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
            if ($serialText.Contains($ExpectSerial)) { $testResult = 0; break }
            if ($testProcess.HasExited) { $testResult = 1; break }
            Start-Sleep -Milliseconds 200
        }
    } finally {
        if ($null -ne $testProcess) {
            if (-not $testProcess.HasExited) { Stop-Process -Id $testProcess.Id -Force }
            $testProcess.WaitForExit()
            $testProcess.Dispose()
        }
        Write-Output "Serial log: $serialLog"
        Write-Output "QEMU stderr: $errorLog"
    }
    if ($testResult -eq 0) { Write-Output "Observed serial marker: $ExpectSerial" }
    else { Write-Output "Serial marker not observed within the bounded run: $ExpectSerial" }
    exit $testResult
}

& $qemu.FullName @qemuArguments -monitor "tcp:127.0.0.1:4444,server=on,wait=off" -serial stdio
exit $LASTEXITCODE
