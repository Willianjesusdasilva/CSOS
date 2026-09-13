param(
    [Parameter(Mandatory = $true)][string]$ClosureArchive,
    [string]$Output = (Join-Path $PSScriptRoot '..\zig-out\nix.img'),
    [int]$SizeMiB = 256
)

$ErrorActionPreference = 'Stop'
$archive = (Resolve-Path -LiteralPath $ClosureArchive).Path
$outputPath = [IO.Path]::GetFullPath($Output)
if ($SizeMiB -lt 128 -or $SizeMiB -gt 2048) { throw 'SizeMiB must be between 128 and 2048.' }
function To-Wsl([string]$value) {
    return "/mnt/" + $value.Substring(0, 1).ToLowerInvariant() + $value.Substring(2).Replace('\', '/')
}
$archiveWsl = To-Wsl $archive
$outputWsl = To-Wsl $outputPath
$outputDirWsl = To-Wsl ([IO.DirectoryInfo]::new((Split-Path -Parent $outputPath)).FullName)
$command = "set -eu; root=/tmp/csos-nix-fat-root; rm -rf `$root; mkdir -p `$root; tar -xf '$archiveWsl' -C `$root; mkdir -p '$outputDirWsl'; truncate -s ${SizeMiB}M '$outputWsl'; mkfs.fat -F 16 -S 512 -s 16 -n CSOSNIX '$outputWsl' >/dev/null; export MTOOLS_SKIP_CHECK=1; mmd -i '$outputWsl' ::/bin ::/lib ::/usr ::/usr/lib; mcopy -o -s -i '$outputWsl' `$root/usr/bin/nix ::/bin/; mcopy -o -s -i '$outputWsl' `$root/usr/lib/* ::/lib/; mcopy -o -s -i '$outputWsl' `$root/usr/lib/* ::/usr/lib/; mcopy -o -i '$outputWsl' `$root/lib/ld-musl-x86_64.so.1 ::/lib/; mcopy -o -i '$outputWsl' `$root/usr/lib/libnixutil.so ::/lib/LIBNIX~1.SO; mcopy -o -i '$outputWsl' `$root/usr/lib/libnixstore.so ::/lib/NIXSTORE.SO; mcopy -o -i '$outputWsl' `$root/usr/lib/libnixexpr.so ::/lib/NIXEXPR.SO; mcopy -o -i '$outputWsl' `$root/usr/lib/libnixcmd.so ::/lib/NIXCMD.SO; mcopy -o -i '$outputWsl' `$root/usr/lib/libnixfetchers.so ::/lib/NIXFETCH.SO; mcopy -o -i '$outputWsl' `$root/usr/lib/libnixflake.so ::/lib/NIXFLAK.SO; mcopy -o -i '$outputWsl' `$root/usr/lib/libnixmain.so ::/lib/NIXMAIN.SO; mcopy -o -i '$outputWsl' `$root/usr/lib/libgc.so.1 ::/lib/LIBGC.SO1; mcopy -o -i '$outputWsl' `$root/usr/lib/libstdc++.so.6 ::/lib/LIBSTD.SO6; mcopy -o -i '$outputWsl' `$root/usr/lib/libgcc_s.so.1 ::/lib/LIBGCC.SO1; mcopy -o -i '$outputWsl' `$root/lib/libc.musl-x86_64.so.1 ::/lib/LIBCMUSL.SO1; mdir -i '$outputWsl' ::/bin; mdir -i '$outputWsl' ::/lib | tail -n 1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libarchive.so.13 ::/lib/LIBARCH.SO3"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libblake3.so.0 ::/lib/LIBBLAK.SO0"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libcrypto.so.3 ::/lib/LIBCRYP.SO3"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libsodium.so.26 ::/lib/SODIUM.SO6"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libbrotlidec.so.1 ::/lib/LIBBROT.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libbrotlienc.so.1 ::/lib/LIBBROE.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libbrotlicommon.so.1 ::/lib/LIBBROC.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libbz2.so.1 ::/lib/LIBBZ2.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libcurl.so.4 ::/lib/LIBCURL.SO4"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libcpuid.so.18 ::/lib/LIBCPUI.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libboost_context.so.1.84.0 ::/lib/BOOSTCON.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libboost_iostreams.so.1.84.0 ::/lib/BOOSTIO.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libboost_url.so.1.84.0 ::/lib/BOOSTURL.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libseccomp.so.2 ::/lib/LIBSECC.SO2"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libsqlite3.so.0 ::/lib/LIBSQLI.SO0"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libgit2.so.1.9 ::/lib/LIBGIT2.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/liblowdown.so.4 ::/lib/LIBLOWD.SO4"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libeditline.so.1 ::/lib/LIBEDIT.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libacl.so.1 ::/lib/LIBACL.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libexpat.so.1 ::/lib/LIBEXPAT.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libzstd.so.1 ::/lib/LIBZSTD.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/liblz4.so.1 ::/lib/LIBLZ4.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/liblzma.so.5 ::/lib/LIBLZMA.SO5"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libtbb.so.12 ::/lib/LIBTBB.SO1"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libtbbmalloc.so.2 ::/lib/TBBMALLO.SO2"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libtbbmalloc_proxy.so.2 ::/lib/TBBPROX.SO2"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libcares.so.2 ::/lib/LIBCARES.SO2"
$command += "; mcopy -o -i '$outputWsl' `$root/usr/lib/libz.so.1 ::/lib/LIBZ.SO1"
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
& wsl.exe -d Ubuntu -- bash -lc "echo $encoded | base64 -d | bash"
if ($LASTEXITCODE -ne 0) { throw "Nix FAT image creation failed ($LASTEXITCODE)" }
Write-Output "Nix FAT image created: $outputPath"
