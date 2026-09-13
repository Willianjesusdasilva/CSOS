param(
    [string]$Disk = (Join-Path $PSScriptRoot '..\zig-out\nvme.img'),
    [string]$Kernel = (Join-Path $PSScriptRoot '..\zig-out\recovery\alpine-extract\vmlinuz-virt'),
    [string]$Initramfs = (Join-Path $PSScriptRoot '..\zig-out\recovery\initramfs-recovery'),
    [string]$Append = 'console=ttyS0 rdinit=/init-recovery',
    [switch]$Ssh,
    [ValidateRange(0, 300)][int]$SmokeTestSeconds = 0,
    [string]$ExpectSerial = 'RECOVERY_GIT_STATUS_OK'
)

$ErrorActionPreference = 'Stop'
$qemu = Join-Path $env:ProgramFiles 'qemu\qemu-system-x86_64.exe'
foreach ($path in @($qemu, $Disk, $Kernel, $Initramfs)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Recovery input not found: $path" }
}

$network = @(); if ($Ssh) { $Append += ' recovery-ssh'; $network = @('-netdev','user,id=recovery,hostfwd=tcp:127.0.0.1:2222-:22','-device','virtio-net-pci,netdev=recovery') }
$qemuArguments = @('-machine','q35','-m','1024','-kernel',(Resolve-Path -LiteralPath $Kernel).Path,
    '-initrd',(Resolve-Path -LiteralPath $Initramfs).Path,'-append',$Append,
    '-drive',"file=$((Resolve-Path -LiteralPath $Disk).Path),format=raw,if=ide",
    '-display','none','-no-reboot') + $network

if ($SmokeTestSeconds -eq 0) {
    & $qemu @qemuArguments -serial stdio
    exit $LASTEXITCODE
}

if ([string]::IsNullOrWhiteSpace($ExpectSerial)) { throw 'ExpectSerial must not be empty' }
$runId = [Guid]::NewGuid().ToString('N')
$serialLog = Join-Path $PSScriptRoot "..\zig-out\recovery\smoke-$runId.serial.log"
$stderrLog = Join-Path $PSScriptRoot "..\zig-out\recovery\smoke-$runId.stderr.log"
$qemuArguments += @('-serial',"file:$([IO.Path]::GetFullPath($serialLog))")
$quotedArguments = $qemuArguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }
$process = $null
try {
    $process = Start-Process -FilePath $qemu -ArgumentList $quotedArguments -PassThru -WindowStyle Hidden -RedirectStandardError ([IO.Path]::GetFullPath($stderrLog))
    if (-not $process.WaitForExit($SmokeTestSeconds * 1000)) {
        throw "Recovery marker not observed within $SmokeTestSeconds seconds"
    }
    $serialText = if (Test-Path -LiteralPath $serialLog) { Get-Content -Raw -LiteralPath $serialLog } else { '' }
    if (-not $serialText.Contains($ExpectSerial)) { throw "Recovery marker not observed: $ExpectSerial" }
    Write-Output "Observed recovery marker: $ExpectSerial"
    Write-Output "Recovery serial log: $([IO.Path]::GetFullPath($serialLog))"
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit()
    }
}
