param(
    [string]$SourceDirectory = (Join-Path $PSScriptRoot '..\zig-out\nix-root\nix'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\zig-out\nix-runtime')
)

$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath($SourceDirectory)
$output = [IO.Path]::GetFullPath($OutputDirectory)

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Nix staging directory not found: $source"
}
$nixBinary = Join-Path $source 'bin\nix'
if (-not (Test-Path -LiteralPath $nixBinary -PathType Leaf)) {
    throw "Nix executable not found: $nixBinary"
}

# Keep this check independent of a host `file` utility. The interpreter string
# is present in a dynamically linked x86_64-musl ELF and prevents accidentally
# packaging a native Windows or glibc build as the CSOS target runtime.
$elf = [IO.File]::ReadAllBytes($nixBinary)
if ($elf.Length -lt 4 -or $elf[0] -ne 0x7f -or $elf[1] -ne 0x45 -or $elf[2] -ne 0x4c -or $elf[3] -ne 0x46) {
    throw "Nix executable is not an ELF binary: $nixBinary"
}
$needle = [Text.Encoding]::ASCII.GetBytes('/lib/ld-musl-x86_64.so.1')
$found = $false
for ($i = 0; $i -le $elf.Length - $needle.Length; $i++) {
    $match = $true
    for ($j = 0; $j -lt $needle.Length; $j++) {
        if ($elf[$i + $j] -ne $needle[$j]) { $match = $false; break }
    }
    if ($match) { $found = $true; break }
}
if (-not $found) { throw 'Nix executable does not reference the x86_64-musl loader.' }

if ($output.TrimEnd('\') -eq $source.TrimEnd('\')) {
    throw 'OutputDirectory must be different from SourceDirectory.'
}
New-Item -ItemType Directory -Force -Path $output | Out-Null
$payload = Join-Path $output 'nix'
New-Item -ItemType Directory -Force -Path $payload | Out-Null
Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $payload -Recurse -Force

# Nix is an x86_64-musl ELF.  The install prefix normally leaves the musl
# loader/libc in the base system, which would make this package look complete
# while remaining unbootable when copied to the standalone CSOS filesystem.
# Include a known-good loader from the reproducible Alpine recovery sysroot
# and expose it under both names used by Nix's dynamic section.
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$muslCandidates = @(
    (Join-Path $workspace 'zig-out\recovery\initramfs-root\usr\lib\ld-musl-x86_64.so.1'),
    (Join-Path $workspace 'zig-out\recovery\cpio-tools\ld-musl-x86_64.so.1')
)
$muslLoader = $muslCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $muslLoader) { throw 'x86_64-musl loader not found; build Alpine recovery before packaging Nix.' }
$nixLib = Join-Path $payload 'lib'
New-Item -ItemType Directory -Force -Path $nixLib | Out-Null
Copy-Item -LiteralPath $muslLoader -Destination (Join-Path $nixLib 'ld-musl-x86_64.so.1') -Force
Copy-Item -LiteralPath $muslLoader -Destination (Join-Path $nixLib 'libc.so') -Force

$files = @(Get-ChildItem -LiteralPath $payload -Recurse -File | Sort-Object { $_.FullName.Substring($payload.Length + 1) })
$bytes = [int64](($files | Measure-Object -Property Length -Sum).Sum)
$manifest = [Collections.Generic.List[string]]::new()
$manifest.Add('CSOS-NIX-RUNTIME-V1')
$manifest.Add('target=/nix')
$manifest.Add("files=$($files.Count)")
$manifest.Add("bytes=$bytes")
foreach ($file in $files) {
    $relative = $file.FullName.Substring($payload.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.Add("$hash`t$($file.Length)`t$relative")
}
$manifestPath = Join-Path $output 'MANIFEST.sha256'
[IO.File]::WriteAllLines($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
Write-Output "Nix runtime packaged: $payload"
Write-Output "Manifest: $manifestPath ($($files.Count) files, $bytes bytes)"
