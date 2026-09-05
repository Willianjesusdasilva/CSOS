param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$SharedLibrary,
    [string]$ExtraLibrary,
    [string]$GpuFirmware,
    [string]$RadvRuntime,
    [string]$LibdrmAmdgpu,
    [string]$Libdrm,
    [string]$Zlib,
    [string]$Libc
)

$sectorSize = 512
$sectorCount = 131072
$sectorsPerCluster = 4
$fatSectors = 128
$rootEntries = 512
$rootSectors = 32
$content = [Text.Encoding]::ASCII.GetBytes("CSOS FAT16 storage ready`n")
$stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite)
try {
    $stream.SetLength($sectorSize * $sectorCount)
    $writer = [IO.BinaryWriter]::new($stream)
    $boot = [byte[]]::new($sectorSize)
    $boot[0] = 0xEB; $boot[1] = 0x3C; $boot[2] = 0x90
    [Text.Encoding]::ASCII.GetBytes('CSOSFAT ') | ForEach-Object -Begin { $i = 3 } -Process { $boot[$i++] = $_ }
    [BitConverter]::GetBytes([uint16]$sectorSize).CopyTo($boot, 11)
    $boot[13] = $sectorsPerCluster
    [BitConverter]::GetBytes([uint16]1).CopyTo($boot, 14)
    $boot[16] = 2
    [BitConverter]::GetBytes([uint16]$rootEntries).CopyTo($boot, 17)
    [BitConverter]::GetBytes([uint32]$sectorCount).CopyTo($boot, 32)
    $boot[21] = 0xF8
    [BitConverter]::GetBytes([uint16]$fatSectors).CopyTo($boot, 22)
    [Text.Encoding]::ASCII.GetBytes('CSOS DISK  ') | ForEach-Object -Begin { $i = 43 } -Process { $boot[$i++] = $_ }
    [Text.Encoding]::ASCII.GetBytes('FAT16   ') | ForEach-Object -Begin { $i = 54 } -Process { $boot[$i++] = $_ }
    $boot[510] = 0x55; $boot[511] = 0xAA
    $writer.Write($boot)
    foreach ($fatStart in @(1, 1 + $fatSectors)) {
        $stream.Position = $fatStart * $sectorSize
        $writer.Write([uint16]0xFFF8); $writer.Write([uint16]0xFFFF); $writer.Write([uint16]0xFFFF)
    }
    $rootStart = 1 + 2 * $fatSectors
    $stream.Position = $rootStart * $sectorSize
    $writer.Write([Text.Encoding]::ASCII.GetBytes('SYSTEM  TXT'))
    $writer.Write([byte]0x20)
    $writer.Write([byte[]]::new(14))
    $writer.Write([uint16]2)
    $writer.Write([uint32]$content.Length)
    $dataStart = $rootStart + $rootSectors
    $stream.Position = $dataStart * $sectorSize
    $writer.Write($content)
    $nextFreeCluster = 3
    if ($SharedLibrary) {
        $library = [IO.File]::ReadAllBytes($SharedLibrary)
        $clusterBytes = $sectorSize * $sectorsPerCluster
        $clusterCount = [Math]::Ceiling($library.Length / $clusterBytes)
        if ($clusterCount -gt 32) { throw 'shared library is too large for bootstrap FAT allocation' }
        foreach ($fatStart in @(1, 1 + $fatSectors)) {
            for ($index = 0; $index -lt $clusterCount; $index++) {
                $cluster = $nextFreeCluster + $index
                $next = if ($index + 1 -eq $clusterCount) { 0xFFFF } else { $cluster + 1 }
                $stream.Position = $fatStart * $sectorSize + $cluster * 2
                $writer.Write([uint16]$next)
            }
        }
        $stream.Position = $rootStart * $sectorSize + 32
        $writer.Write([Text.Encoding]::ASCII.GetBytes('LIBCSOS SO '))
        $writer.Write([byte]0x20)
        $writer.Write([byte[]]::new(14))
        $writer.Write([uint16]$nextFreeCluster)
        $writer.Write([uint32]$library.Length)
        $stream.Position = $dataStart * $sectorSize + ($nextFreeCluster - 2) * $clusterBytes
        $writer.Write($library)
        $nextFreeCluster += $clusterCount
    }
    if ($ExtraLibrary) {
        $library = [IO.File]::ReadAllBytes($ExtraLibrary)
        $clusterBytes = $sectorSize * $sectorsPerCluster
        $clusterCount = [Math]::Ceiling($library.Length / $clusterBytes)
        if ($clusterCount -gt 32) { throw 'extra library is too large for bootstrap FAT allocation' }
        foreach ($fatStart in @(1, 1 + $fatSectors)) {
            for ($index = 0; $index -lt $clusterCount; $index++) {
                $cluster = $nextFreeCluster + $index
                $next = if ($index + 1 -eq $clusterCount) { 0xFFFF } else { $cluster + 1 }
                $stream.Position = $fatStart * $sectorSize + $cluster * 2
                $writer.Write([uint16]$next)
            }
        }
        $stream.Position = $rootStart * $sectorSize + 64
        $writer.Write([Text.Encoding]::ASCII.GetBytes('LIBEXTRASO '))
        $writer.Write([byte]0x20)
        $writer.Write([byte[]]::new(14))
        $writer.Write([uint16]$nextFreeCluster)
        $writer.Write([uint32]$library.Length)
        $stream.Position = $dataStart * $sectorSize + ($nextFreeCluster - 2) * $clusterBytes
        $writer.Write($library)
        $nextFreeCluster += $clusterCount
    }
    if ($GpuFirmware) {
        $firmware = [IO.File]::ReadAllBytes($GpuFirmware)
        $clusterBytes = $sectorSize * $sectorsPerCluster
        $clusterCount = [int][Math]::Ceiling($firmware.Length / $clusterBytes)
        if ($clusterCount -eq 0) { throw 'GPU firmware archive is empty' }
        $lastCluster = $nextFreeCluster + $clusterCount - 1
        $availableLastCluster = [Math]::Min(0xFFEF, [int](($sectorCount - $dataStart) / $sectorsPerCluster) + 1)
        if ($lastCluster -gt $availableLastCluster) { throw 'GPU firmware archive does not fit on the CSOS disk' }
        foreach ($fatStart in @(1, 1 + $fatSectors)) {
            for ($index = 0; $index -lt $clusterCount; $index++) {
                $cluster = $nextFreeCluster + $index
                $next = if ($index + 1 -eq $clusterCount) { 0xFFFF } else { $cluster + 1 }
                $stream.Position = $fatStart * $sectorSize + $cluster * 2
                $writer.Write([uint16]$next)
            }
        }
        $stream.Position = $rootStart * $sectorSize + 96
        $writer.Write([Text.Encoding]::ASCII.GetBytes('GPUFW   BIN'))
        $writer.Write([byte]0x20)
        $writer.Write([byte[]]::new(14))
        $writer.Write([uint16]$nextFreeCluster)
        $writer.Write([uint32]$firmware.Length)
        $stream.Position = $dataStart * $sectorSize + ($nextFreeCluster - 2) * $clusterBytes
        $writer.Write($firmware)
        $nextFreeCluster += $clusterCount
    }
    $runtimeFiles = @(
        @{ Path = $RadvRuntime; Name = 'RADV    SO ' },
        @{ Path = $LibdrmAmdgpu; Name = 'DRMAMD  SO1' },
        @{ Path = $Libdrm; Name = 'LIBDRM  SO2' },
        @{ Path = $Zlib; Name = 'LIBZ    SO1' },
        @{ Path = $Libc; Name = 'LIBC    SO ' }
    )
    $runtimeEntry = if ($GpuFirmware) { 4 } else { 3 }
    foreach ($runtimeFile in $runtimeFiles) {
        if (-not $runtimeFile.Path) { continue }
        $library = [IO.File]::ReadAllBytes($runtimeFile.Path)
        if ($library.Length -eq 0 -or $library.Length -gt 32MB) { throw "$($runtimeFile.Path) has an invalid runtime size" }
        $clusterBytes = $sectorSize * $sectorsPerCluster
        $clusterCount = [int][Math]::Ceiling($library.Length / $clusterBytes)
        $lastCluster = $nextFreeCluster + $clusterCount - 1
        $availableLastCluster = [Math]::Min(0xFFEF, [int](($sectorCount - $dataStart) / $sectorsPerCluster) + 1)
        if ($lastCluster -gt $availableLastCluster) { throw "$($runtimeFile.Path) does not fit on the CSOS disk" }
        foreach ($fatStart in @(1, 1 + $fatSectors)) {
            for ($index = 0; $index -lt $clusterCount; $index++) {
                $cluster = $nextFreeCluster + $index
                $next = if ($index + 1 -eq $clusterCount) { 0xFFFF } else { $cluster + 1 }
                $stream.Position = $fatStart * $sectorSize + $cluster * 2
                $writer.Write([uint16]$next)
            }
        }
        $stream.Position = $rootStart * $sectorSize + $runtimeEntry * 32
        $writer.Write([Text.Encoding]::ASCII.GetBytes($runtimeFile.Name))
        $writer.Write([byte]0x20)
        $writer.Write([byte[]]::new(14))
        $writer.Write([uint16]$nextFreeCluster)
        $writer.Write([uint32]$library.Length)
        $stream.Position = $dataStart * $sectorSize + ($nextFreeCluster - 2) * $clusterBytes
        $writer.Write($library)
        $nextFreeCluster += $clusterCount
        $runtimeEntry += 1
    }
} finally {
    $stream.Dispose()
}
