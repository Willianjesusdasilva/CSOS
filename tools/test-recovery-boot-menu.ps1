param(
    [string]$EspDirectory = (Join-Path $PSScriptRoot '..\zig-out\recovery-esp'),
    [string]$Disk = (Join-Path $PSScriptRoot '..\zig-out\nvme.img'),
    [ValidateRange(5, 120)][int]$TimeoutSeconds = 20
)
$ErrorActionPreference = 'Stop'
$qemu = Join-Path $env:ProgramFiles 'qemu\qemu-system-x86_64.exe'
$ovmf = Join-Path $env:ProgramFiles 'qemu\share\edk2-x86_64-code.fd'
foreach ($path in @($qemu, $ovmf, $EspDirectory, $Disk)) { if (-not (Test-Path -LiteralPath $path)) { throw "Boot test input not found: $path" } }
$id = [Guid]::NewGuid().ToString('N')
$serial = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\zig-out\recovery\boot-menu-$id.serial.log"))
$stderr = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\zig-out\recovery\boot-menu-$id.stderr.log"))
$args = @('-machine','q35','-m','1024M','-drive',"if=pflash,format=raw,readonly=on,file=$([IO.Path]::GetFullPath($ovmf))",'-drive',"format=raw,file=fat:rw:$([IO.Path]::GetFullPath($EspDirectory))",'-drive',"file=$([IO.Path]::GetFullPath($Disk)),format=raw,if=ide",'-display','none','-serial',"file:$serial",'-no-reboot')
$quoted = $args | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }
$p = $null
try {
    $p = Start-Process -FilePath $qemu -ArgumentList $quoted -PassThru -WindowStyle Hidden -RedirectStandardError $stderr
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { throw "Boot menu did not reach a terminal state within $TimeoutSeconds seconds" }
    $serialText = if (Test-Path -LiteralPath $serial) { Get-Content -Raw -LiteralPath $serial } else { '' }
    if ($serialText -notmatch 'RECOVERY_MOUNT_OK|RECOVERY_MOUNT_FAILED') { throw "Recovery entry did not boot; serial log: $serial" }
    Write-Output 'Recovery boot menu selected and Alpine entry started.'
    Write-Output "Serial log: $serial"
} finally {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $p.WaitForExit(5000) | Out-Null }
}
