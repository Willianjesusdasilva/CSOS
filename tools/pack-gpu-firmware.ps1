param(
    [string]$AmdDirectory,
    [string]$NvidiaDirectory,
    [string[]]$Mapping,
    [Parameter(Mandatory = $true)][string]$Output
)

if (-not $AmdDirectory -and -not $NvidiaDirectory) { throw 'At least one GPU firmware directory is required' }
$stream = [IO.File]::Open($Output, [IO.FileMode]::Create, [IO.FileAccess]::Write)
try {
    $writeEntry = {
        param([string]$Name, [byte[]]$Data, [int]$Inode)
        $nameBytes = [Text.Encoding]::UTF8.GetBytes($Name + [char]0)
        $fields = @($Inode, 0x81A4, 0, 0, 1, 0, $Data.Length, 0, 0, 0, 0, $nameBytes.Length, 0)
        $header = '070701' + (($fields | ForEach-Object { '{0:x8}' -f $_ }) -join '')
        $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $stream.Write($nameBytes, 0, $nameBytes.Length)
        while (($stream.Position % 4) -ne 0) { $stream.WriteByte(0) }
        $stream.Write($Data, 0, $Data.Length)
        while (($stream.Position % 4) -ne 0) { $stream.WriteByte(0) }
    }
    $inode = 1
    $sources = @()
    if ($AmdDirectory) { $sources += [pscustomobject]@{ Path = $AmdDirectory; Prefix = 'amdgpu' } }
    if ($NvidiaDirectory) { $sources += [pscustomobject]@{ Path = $NvidiaDirectory; Prefix = 'nouveau' } }
    foreach ($source in $sources) {
        $root = [IO.Path]::GetFullPath($source.Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "GPU firmware directory was not found: $root" }
        Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName | ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
            & $writeEntry ($source.Prefix + '/' + $relative) ([IO.File]::ReadAllBytes($_.FullName)) $inode
            $inode += 1
        }
    }
    if ($Mapping) {
        foreach ($line in $Mapping) {
            if ($line -notmatch '^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}(:[0-9A-Fa-f]{2})?(@[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})?=(amdgpu|nouveau)/[^|]+/(\|(security|management|memory|graphics|dma|display|media|discovery|other|psp-host-boot)(,(security|management|memory|graphics|dma|display|media|discovery|other|psp-host-boot))*)?$') { throw "Invalid GPU firmware mapping: $line" }
            $requirementsAt = $line.IndexOf('|')
            if ($requirementsAt -ge 0) {
                $requirements = $line.Substring($requirementsAt + 1).Split(',')
                if (($requirements | Select-Object -Unique).Count -ne $requirements.Count) { throw "Duplicate GPU firmware requirement: $line" }
                if ($requirements -contains 'psp-host-boot') {
                    $identity = $line.Substring(0, $line.IndexOf('='))
                    $target = $line.Substring($line.IndexOf('=') + 1, $requirementsAt - $line.IndexOf('=') - 1)
                    if ($identity -notmatch '^1002:[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}@[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$' -or
                        -not $target.StartsWith('amdgpu/') -or
                        $requirements -notcontains 'security' -or $requirements -notcontains 'discovery') {
                        throw "Unsafe PSP host boot mapping: $line"
                    }
                }
            }
        }
        $manifest = [Text.Encoding]::ASCII.GetBytes(($Mapping -join "`n") + "`n")
        & $writeEntry 'csos-gpu.conf' $manifest $inode
        $inode += 1
    }
    & $writeEntry 'TRAILER!!!' ([byte[]]::new(0)) $inode
} finally {
    $stream.Dispose()
}
