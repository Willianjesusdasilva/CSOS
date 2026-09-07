param(
    [Parameter(Mandatory = $true)][string]$EfiBinary,
    [Parameter(Mandatory = $true)][string]$SharedLibrary,
    [Parameter(Mandatory = $true)][string]$ExtraLibrary,
    [string]$GpuFirmware,
    [string]$RadvRuntime,
    [string]$LibdrmAmdgpu,
    [string]$Libdrm,
    [string]$Zlib,
    [string]$Libc,
    [switch]$UsbAudio,
    [switch]$ResetDisk,
    [string]$AudioBackend = 'none',
    [ValidateRange(0, 300)][int]$SmokeTestSeconds = 0,
    [string]$ExpectSerial = 'CSOS M14 userspace DRM core ready',
    [switch]$SmokeDesktopFiles,
    [switch]$SmokeDesktopMouse
)

$ErrorActionPreference = 'Stop'
if ($RadvRuntime -and (-not $LibdrmAmdgpu -or -not $Libdrm -or -not $Zlib -or -not $Libc)) {
    throw 'RadvRuntime requires LibdrmAmdgpu, Libdrm, Zlib, and Libc runtime paths.'
}

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
if ($ResetDisk -or $GpuFirmware -or $RadvRuntime -or -not (Test-Path -LiteralPath $nvmeDisk)) {
    & (Join-Path $PSScriptRoot 'make-fat16.ps1') -Path $nvmeDisk -SharedLibrary $SharedLibrary -ExtraLibrary $ExtraLibrary -GpuFirmware $GpuFirmware `
        -RadvRuntime $RadvRuntime -LibdrmAmdgpu $LibdrmAmdgpu -Libdrm $Libdrm -Zlib $Zlib -Libc $Libc
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
    $monitorPort = $null
    $monitorTarget = 'none'
    if ($SmokeDesktopFiles -or $SmokeDesktopMouse) {
        $reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $reservation.Start()
        try { $monitorPort = ([Net.IPEndPoint]$reservation.LocalEndpoint).Port } finally { $reservation.Stop() }
        $monitorTarget = "tcp:127.0.0.1:$monitorPort,server=on,wait=off"
    }
    $qemuArguments += @('-display', 'none', '-monitor', $monitorTarget, '-serial', "file:$serialLog")
    # Start-Process joins ArgumentList into a Windows command line. Quote each
    # argument explicitly so installation/workspace paths with spaces survive.
    $quotedArguments = $qemuArguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
    $testProcess = $null
    $testResult = 124
    $uiInjected = $false
    $mouseInjected = $false
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
            if ($SmokeDesktopFiles -and -not $uiInjected -and $serialText.Contains('CSOS graphical session ready')) {
                $monitor = [Net.Sockets.TcpClient]::new()
                try {
                    $monitor.Connect('127.0.0.1', $monitorPort)
                    $writer = [IO.StreamWriter]::new($monitor.GetStream())
                    try {
                        $writer.AutoFlush = $true
                        foreach ($key in @('meta_l', 'down', 'down', 'down', 'ret', 'down', 'ret', 'pgdn', 'pgup', 'esc')) {
                            $writer.WriteLine("sendkey $key")
                            Start-Sleep -Milliseconds 180
                        }
                    } finally { $writer.Dispose() }
                    $uiInjected = $true
                    Write-Output 'Injected desktop smoke sequence: launcher -> FILES -> preview -> page -> back'
                } finally { $monitor.Dispose() }
            }
            if ($SmokeDesktopMouse -and -not $mouseInjected -and $serialText.Contains('CSOS graphical session ready')) {
                $monitor = [Net.Sockets.TcpClient]::new()
                try {
                    $monitor.Connect('127.0.0.1', $monitorPort)
                    $writer = [IO.StreamWriter]::new($monitor.GetStream())
                    try {
                        $writer.AutoFlush = $true
                        foreach ($command in @('mouse_move -120 -107', 'mouse_move -120 -107', 'mouse_move 0 -106', 'mouse_button 1', 'mouse_button 0')) {
                            $writer.WriteLine($command)
                            Start-Sleep -Milliseconds 220
                        }
                    } finally { $writer.Dispose() }
                    $mouseInjected = $true
                    Write-Output 'Injected desktop mouse smoke sequence: move -> press -> release'
                } finally { $monitor.Dispose() }
            }
            $observed = $serialText.Contains($ExpectSerial)
            if ($SmokeDesktopFiles) {
                $observed = $observed -and
                    $serialText.Contains('UI launch application (keyboard): 4') -and
                    $serialText.Contains('UI files selected:') -and
                    $serialText.Contains('UI files preview offset: 192') -and
                    $serialText.Contains('UI files preview closed')
            }
            if ($SmokeDesktopMouse) {
                $observed = $observed -and
                    $serialText.Contains('UI pointer moved:') -and
                    $serialText.Contains('UI mouse buttons: 1') -and
                    $serialText.Contains('UI mouse buttons: 0')
            }
            if ($observed) { $testResult = 0; break }
            if ($testProcess.HasExited) { $testResult = 1; break }
            Start-Sleep -Milliseconds 200
        }
    } finally {
        if ($null -ne $testProcess) {
            if (-not $testProcess.HasExited) {
                # Bound shutdown so smoke tests never leave the emulator open.
                # Stop the exact emulator first; taskkill tree enumeration can
                # itself stall on some Windows hosts after QEMU has completed.
                Stop-Process -Id $testProcess.Id -Force -ErrorAction SilentlyContinue
                if (-not $testProcess.WaitForExit(5000)) {
                    & taskkill.exe /PID $testProcess.Id /T /F *> $null
                }
            }
            if (-not $testProcess.HasExited -and -not $testProcess.WaitForExit(5000)) {
                throw "QEMU process $($testProcess.Id) did not terminate after bounded cleanup."
            }
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
