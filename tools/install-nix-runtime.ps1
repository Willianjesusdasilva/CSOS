param(
    [string]$RuntimeDirectory = (Join-Path $PSScriptRoot '..\zig-out\nix-runtime'),
    [Parameter(Mandatory = $true)][string]$DestinationDirectory
)

$ErrorActionPreference = 'Stop'
$runtime = [IO.Path]::GetFullPath((Join-Path $RuntimeDirectory 'nix'))
$manifest = Join-Path ([IO.Path]::GetFullPath($RuntimeDirectory)) 'MANIFEST.sha256'
$destination = [IO.Path]::GetFullPath($DestinationDirectory)
if (-not (Test-Path -LiteralPath $runtime -PathType Container)) { throw "Packaged Nix runtime not found: $runtime" }
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Runtime manifest not found: $manifest" }
if ($destination -eq [IO.Path]::GetPathRoot($destination)) { throw 'Refusing to install Nix into a filesystem root.' }

$nix = Join-Path $destination 'nix'
New-Item -ItemType Directory -Force -Path $nix | Out-Null
Get-ChildItem -LiteralPath $runtime -Force | Copy-Item -Destination $nix -Recurse -Force
Copy-Item -Force -LiteralPath $manifest -Destination (Join-Path $nix 'CSOS-MANIFEST.sha256')
if (-not (Test-Path -LiteralPath (Join-Path $nix 'bin\nix') -PathType Leaf)) { throw 'Nix installation did not produce /nix/bin/nix.' }
Write-Output "Installed CSOS Nix runtime at $nix"
