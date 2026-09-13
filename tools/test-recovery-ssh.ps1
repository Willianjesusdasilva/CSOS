[CmdletBinding()]
param(
    [string] $Disk,
    [string] $Kernel,
    [string] $Initramfs,
    [Parameter(Mandatory)] [string] $IdentityFile,
    [string] $Command = 'echo RECOVERY_SSH_COMMAND_OK',
    [ValidateRange(5, 120)] [int] $TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Disk) { $Disk = Join-Path $repoRoot 'zig-out\nvme.img' }
if (-not $Kernel) { $Kernel = Join-Path $repoRoot 'zig-out\recovery\alpine-extract\vmlinuz-virt' }
if (-not $Initramfs) { $Initramfs = Join-Path $repoRoot 'zig-out\recovery\initramfs-recovery' }
$qemu = Join-Path $env:ProgramFiles 'qemu\qemu-system-x86_64.exe'
foreach ($path in @($qemu, $Disk, $Kernel, $Initramfs, $IdentityFile)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Recovery SSH input not found: $path" }
}
$qemuArguments = @(
    '-machine', 'q35', '-m', '1024',
    '-kernel', (Resolve-Path -LiteralPath $Kernel).Path,
    '-initrd', (Resolve-Path -LiteralPath $Initramfs).Path,
    '-append', 'console=ttyS0 rdinit=/init-recovery recovery-ssh',
    '-drive', "file=$((Resolve-Path -LiteralPath $Disk).Path),format=raw,if=ide",
    '-display', 'none', '-no-reboot',
    '-netdev', 'user,id=recovery,hostfwd=tcp:127.0.0.1:2222-:22',
    '-device', 'virtio-net-pci,netdev=recovery'
)
$runId = [Guid]::NewGuid().ToString('N')
$serialLog = Join-Path $PSScriptRoot "..\zig-out\recovery\ssh-$runId.serial.log"
$qemuArguments += @('-serial', "file:$([IO.Path]::GetFullPath($serialLog))")
$quotedArguments = $qemuArguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
$process = $null
try {
    $process = Start-Process -FilePath $qemu -ArgumentList $quotedArguments -PassThru -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $ready = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try { $serial = Get-Content -Raw -LiteralPath $serialLog -ErrorAction Stop } catch { $serial = '' }
        if ($null -eq $serial) { $serial = '' }
        if ($serial.Contains('RECOVERY_SSH_READY')) { $ready = $true; break }
        if ($process.HasExited) { throw "Recovery QEMU exited before SSH readiness" }
    }
    if (-not $ready) { throw "RECOVERY_SSH_READY not observed within $TimeoutSeconds seconds" }
    $ssh = Get-Command ssh.exe -ErrorAction Stop
    $sshArguments = @(
        '-i', (Resolve-Path -LiteralPath $IdentityFile).Path,
        '-p', '2222', '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR',
        '-o', "ConnectTimeout=$TimeoutSeconds", 'root@127.0.0.1', $Command
    )
    $result = & $ssh.Source @sshArguments 2>&1
    $result | ForEach-Object { Write-Output $_ }
    if ($LASTEXITCODE -ne 0) { throw "SSH command failed ($LASTEXITCODE)" }
    Write-Output 'Recovery SSH command passed.'
    Write-Output "Recovery serial log: $([IO.Path]::GetFullPath($serialLog))"
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000)
    }
    if ($process) { $process.Dispose() }
}
