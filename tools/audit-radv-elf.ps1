param([string]$Library, [switch]$Stripped)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/..").Path
if (-not $Library) { $Library = Join-Path $workspace 'zig-out/mesa-radv/src/amd/vulkan/libvulkan_radeon.so' }
$library = $Library
if (-not (Test-Path -LiteralPath $library)) { throw 'Build RADV before auditing its ELF.' }
$readelf = (Get-Command readelf.exe -ErrorAction Stop).Source
$nm = (Get-Command nm.exe -ErrorAction Stop).Source
$loaderSource = Get-Content -LiteralPath (Join-Path $workspace 'kernel/process.zig') -Raw
if ($loaderSource -notmatch 'const max_mappings = (\d+);') { throw 'Could not read loader mapping capacity.' }
[uint64]$loaderCapacity = $matches[1]

$header = (& $readelf -hW $library) -join "`n"
if ($LASTEXITCODE -ne 0 -or $header -notmatch 'Class:\s+ELF64' -or
    $header -notmatch 'Type:\s+DYN' -or $header -notmatch 'Machine:\s+Advanced Micro Devices X86-64') {
    throw 'RADV output is not an ELF64 x86-64 shared object.'
}

$dynamic = (& $readelf -dW $library) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Could not read the RADV dynamic section.' }
if ($dynamic -match '\((?:RPATH|RUNPATH)\)') { throw 'RADV ELF contains a host/runtime search path.' }
if ($dynamic -notmatch '\(SONAME\).*\[libvulkan_radeon\.so\]') { throw 'Unexpected RADV SONAME.' }
$needed = [regex]::Matches($dynamic, '\(NEEDED\).*\[([^\]]+)\]') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object
$expectedNeeded = @('libc.so', 'libdrm.so.2', 'libdrm_amdgpu.so.1', 'libz.so.1') | Sort-Object
if (($needed -join "`n") -ne ($expectedNeeded -join "`n")) {
    throw "Unexpected RADV dependencies: $($needed -join ', ')"
}

$exports = & $nm -D --defined-only --format=posix $library
if ($LASTEXITCODE -ne 0) { throw 'Could not read RADV dynamic exports.' }
$exportNames = @($exports | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object)
$expectedExports = @(
    'vk_icdGetInstanceProcAddr',
    'vk_icdGetPhysicalDeviceProcAddr',
    'vk_icdNegotiateLoaderICDInterfaceVersion'
) | Sort-Object
if (($exportNames -join "`n") -ne ($expectedExports -join "`n")) {
    throw "Unexpected RADV exports: $($exportNames -join ', ')"
}

$dynamicSymbols = (& $readelf --dyn-syms -W $library) -join "`n"
if ($dynamicSymbols -match '__cpu_indicator_init|__cpu_model') {
    throw 'The compiler-rt CPU model leaked into the dynamic symbol table.'
}
if (-not $Stripped) {
    $symbols = (& $readelf -sW $library) -join "`n"
    foreach ($symbol in @('__cpu_indicator_init', '__cpu_model')) {
        if ($symbols -notmatch "LOCAL\s+HIDDEN\s+\d+\s+$symbol(?:`n|$)") {
            throw "$symbol is missing or is not local/hidden."
        }
    }
}

$relocations = & $readelf -rW $library
if ($LASTEXITCODE -ne 0) { throw 'Could not read RADV relocations.' }
$types = @($relocations | ForEach-Object {
    if ($_ -match 'R_X86_64_[A-Z0-9_]+') { $matches[0] }
} | Sort-Object -Unique)
$supported = @('R_X86_64_DTPMOD64', 'R_X86_64_GLOB_DAT', 'R_X86_64_JUMP_SLOT', 'R_X86_64_RELATIVE')
$unsupported = @($types | Where-Object { $_ -notin $supported })
if ($unsupported.Count -ne 0) { throw "Unsupported RADV relocations: $($unsupported -join ', ')" }

$programHeaders = & $readelf -lW $library
if ($LASTEXITCODE -ne 0) { throw 'Could not read RADV program headers.' }
[uint64]$mappedPages = 0
foreach ($line in $programHeaders) {
    if ($line -notmatch '^\s*LOAD\s+\S+\s+(0x[0-9a-f]+)\s+\S+\s+\S+\s+(0x[0-9a-f]+)') { continue }
    [uint64]$virtual = [Convert]::ToUInt64($matches[1].Substring(2), 16)
    [uint64]$memory = [Convert]::ToUInt64($matches[2].Substring(2), 16)
    [uint64]$first = $virtual - ($virtual % 4096)
    [uint64]$last = ($virtual + $memory + 4095) - (($virtual + $memory + 4095) % 4096)
    $mappedPages += ($last - $first) / 4096
}
if ($mappedPages -eq 0 -or $mappedPages -gt $loaderCapacity) {
    throw "RADV needs $mappedPages pages; loader capacity is $loaderCapacity."
}

Write-Output "RADV ELF audit passed: $mappedPages mapped pages, $($types.Count) supported relocation types."
