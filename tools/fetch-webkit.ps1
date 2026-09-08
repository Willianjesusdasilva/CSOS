# Fetch the exact upstream source used by the CSOS port. This does not build
# or install WebKit, and never modifies an existing dirty checkout.
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
$source = Join-Path $workspace '.tools/webkit-src'
$revision = '3bcefb149bd7e5645d18c3f0b9abd515b274649f'
if (-not (Test-Path -LiteralPath $source)) {
    & git init $source
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize WebKit checkout.' }
    & git -C $source remote add origin https://github.com/WebKit/WebKit.git
    if ($LASTEXITCODE -ne 0) { throw 'Cannot configure WebKit remote.' }
}
$remote = & git -C $source remote get-url origin
if ($LASTEXITCODE -ne 0 -or $remote -ne 'https://github.com/WebKit/WebKit.git') {
    throw 'Unexpected WebKit source remote; existing checkout preserved.'
}
$changes = & git -C $source status --porcelain
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'WebKit checkout must be clean.' }
& git -C $source fetch --depth=1 origin $revision
if ($LASTEXITCODE -ne 0) { throw 'Pinned WebKit fetch failed.' }
& git -C $source switch --detach $revision
if ($LASTEXITCODE -ne 0) { throw 'Cannot select pinned WebKit source.' }
$actual = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actual -ne $revision) { throw 'WebKit revision mismatch.' }
Write-Output "WPE WebKit 2.52.6 source ready: $source ($revision); engine not built."
