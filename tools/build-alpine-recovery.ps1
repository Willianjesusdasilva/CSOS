[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BaseInitramfs,
    [Parameter(Mandatory)] [string] $PayloadRoot,
    [string] $RecoveryScript,
    [string] $Output,
    [string] $Cpio
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $RecoveryScript) { $RecoveryScript = Join-Path $repoRoot 'recovery\init-recovery' }
if (-not $Output) { $Output = Join-Path $repoRoot 'zig-out\recovery\initramfs-recovery' }
if (-not $Cpio) { $Cpio = Join-Path $repoRoot 'zig-out\recovery\cpio-tools\cpio' }
foreach ($path in @($BaseInitramfs, $PayloadRoot, $RecoveryScript, $Cpio)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing recovery input: $path" }
}
$base = (Resolve-Path -LiteralPath $BaseInitramfs).Path
$root = (Resolve-Path -LiteralPath $PayloadRoot).Path
$script = (Resolve-Path -LiteralPath $RecoveryScript).Path
$output = [IO.Path]::GetFullPath($Output)
$cpio = (Resolve-Path -LiteralPath $Cpio).Path
$repo = $repoRoot

function Convert-ToWslPath([string] $value) {
    $drive = $value.Substring(0, 1).ToLowerInvariant()
    $rest = $value.Substring(2).Replace('\', '/')
    return "/mnt/host/$drive$rest"
}
function Quote-Sh([string] $value) { return "'" + $value.Replace("'", "'\\''") + "'" }

$baseWsl = Convert-ToWslPath $base
$rootWsl = Convert-ToWslPath $root
$scriptWsl = Convert-ToWslPath $script
$outputWsl = Convert-ToWslPath $output
$cpioWsl = Convert-ToWslPath $cpio
$workWsl = Convert-ToWslPath (Join-Path $repo 'zig-out\recovery\linux-work')
$logWsl = Convert-ToWslPath (Join-Path $repo 'zig-out\recovery\cpio-extract.log')
$command = @"
set -eu
base=$(Quote-Sh $baseWsl)
root=$(Quote-Sh $rootWsl)
script=$(Quote-Sh $scriptWsl)
output=$(Quote-Sh $outputWsl)
cpio=$(Quote-Sh $cpioWsl)
work=$(Quote-Sh $workWsl)
rm -rf "`$work"
mkdir -p "`$work"
cd "`$work"
/usr/bin/cpio -idm < "`$base" > $(Quote-Sh $logWsl) 2>&1
cd "`$root/usr"
find . -type f -size +0c -print0 | while IFS= read -r -d '' f; do
    target="`$work/usr/`${f#./}"
    mkdir -p "`$(dirname "`$target")"
    cp -p "`$root/usr/`${f#./}" "`$target"
done
cd "`$root"
find . -type f -size +0c -print0 | while IFS= read -r -d '' f; do
    target="`$work/`${f#./}"
    mkdir -p "`$(dirname "`$target")"
    cp -p "`$root/`${f#./}" "`$target"
done
# APK extraction on Windows materializes symlinks as empty placeholders;
# recreate the two Dropbear ABI links in the Linux cpio staging tree.
ln -sf libskarnet.so.2.15.1.0 "`$work/usr/lib/libskarnet.so.2.15"
ln -sf libutmps.so.0.1.3.4 "`$work/usr/lib/libutmps.so.0.1"
cp -p "`$script" "`$work/init-recovery"
chmod 755 "`$work/init-recovery"
cd "`$work"
find . -mindepth 1 -print0 | sort -z | /usr/bin/cpio -0 -o -H newc > "`$output"
chmod 644 "`$output"
ls -l "`$output"
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
& wsl.exe -- sh -lc "echo $encoded | base64 -d | sh"
if ($LASTEXITCODE -ne 0) { throw "Recovery initramfs build failed ($LASTEXITCODE)" }
