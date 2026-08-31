param(
    [Parameter(Mandatory = $true)][string]$InputDirectory,
    [Parameter(Mandatory = $true)][string]$Output
)

$root = [IO.Path]::GetFullPath($InputDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'GPU firmware input directory was not found' }
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
    Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
        & $writeEntry $relative ([IO.File]::ReadAllBytes($_.FullName)) $inode
        $inode += 1
    }
    & $writeEntry 'TRAILER!!!' ([byte[]]::new(0)) $inode
} finally {
    $stream.Dispose()
}
