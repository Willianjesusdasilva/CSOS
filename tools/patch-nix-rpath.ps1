param(
    [string]$RuntimeDirectory = (Join-Path $PSScriptRoot '..\zig-out\nix-runtime')
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $RuntimeDirectory 'nix'))
$hostPath = [Text.Encoding]::ASCII.GetBytes('C:/git/csos/zig-out/nix-sysroot-wsl/usr/lib')
$targetPath = [Text.Encoding]::ASCII.GetBytes('/nix/lib')
$files = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'bin') -Recurse -File -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Recurse -File -ErrorAction SilentlyContinue
)
$patched = 0
foreach ($file in $files) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -lt $hostPath.Length -or $bytes.Length -lt 4 -or
        $bytes[0] -ne 0x7f -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4c -or $bytes[3] -ne 0x46) { continue }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $index = $text.IndexOf('C:/git/csos/zig-out/nix-sysroot-wsl/usr/lib', [StringComparison]::Ordinal)
    $found = $index -ge 0
    while ($index -ge 0) {
        for ($j = 0; $j -lt $hostPath.Length; $j++) { $bytes[$index + $j] = if ($j -lt $targetPath.Length) { $targetPath[$j] } else { 0 } }
        $index = $text.IndexOf('C:/git/csos/zig-out/nix-sysroot-wsl/usr/lib', $index + $hostPath.Length, [StringComparison]::Ordinal)
    }
    if ($found) { [IO.File]::WriteAllBytes($file.FullName, $bytes); $patched++ }
}
Write-Output "Patched Nix ELF RUNPATH files: $patched"
