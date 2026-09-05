"""Reject link-only libc stubs and audit the runtime needed by CSOS."""
import pathlib
import re
import subprocess
import sys


def audit(path):
    def readelf(*args):
        return subprocess.check_output(["readelf", *args, str(path)], text=True)

    header = readelf("-hW")
    if not all(value in header for value in ("ELF64", "DYN", "X86-64")):
        raise RuntimeError("Expected ELF64 x86-64 shared object")
    dynamic = readelf("-dW")
    if not re.search(r"\(SONAME\).*\[libc\.so\]", dynamic):
        raise RuntimeError("Missing libc.so SONAME")
    if re.search(r"\((NEEDED|RPATH|RUNPATH|TEXTREL)\)", dynamic):
        raise RuntimeError("Unexpected runtime dependency, search path or text relocation")
    executable = []
    for line in readelf("-lW").splitlines():
        fields = line.split()
        if fields and fields[0] == "LOAD" and "E" in fields[6:-1]:
            start = int(fields[2], 16)
            executable.append((start, start + int(fields[4], 16)))
    symbols = {}
    for line in readelf("--dyn-syms", "-W").splitlines():
        fields = line.split()
        if len(fields) >= 8 and fields[3] == "FUNC" and fields[6] != "UND":
            symbols[fields[7].split("@")[0]] = int(fields[1], 16)
    for name in ("strlen", "memcpy", "malloc", "free", "pthread_create", "dlopen", "__libc_start_main"):
        address = symbols.get(name)
        if address is None or not any(start <= address < end for start, end in executable):
            raise RuntimeError(f"{name} is not an exported function backed by executable bytes")
    kinds = set(re.findall(r"R_X86_64_[A-Z0-9_]+", readelf("-rW")))
    if kinds - {"R_X86_64_RELATIVE", "R_X86_64_GLOB_DAT", "R_X86_64_JUMP_SLOT"}:
        raise RuntimeError(f"Unsupported relocations: {sorted(kinds)}")
    print(f"musl ELF audit passed: {path.stat().st_size} bytes; runtime execution still requires a boot test")


if __name__ == "__main__":
    audit(pathlib.Path(sys.argv[1]).resolve())
