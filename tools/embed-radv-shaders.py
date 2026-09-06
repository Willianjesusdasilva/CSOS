"""Convert audited little-endian SPIR-V modules into a C header."""
import pathlib
import struct
import sys


def module(path: pathlib.Path, name: str) -> str:
    data = path.read_bytes()
    if len(data) < 20 or len(data) % 4:
        raise RuntimeError(f"{path} is not a complete SPIR-V module")
    words = struct.unpack(f"<{len(data) // 4}I", data)
    if words[0] != 0x07230203:
        raise RuntimeError(f"{path} has the wrong SPIR-V magic")
    body = ",\n    ".join(
        ", ".join(f"0x{word:08x}u" for word in words[index:index + 8])
        for index in range(0, len(words), 8)
    )
    return (
        f"static const uint32_t {name}[] = {{\n    {body}\n}};\n"
        f"static const uint32_t {name}_bytes = sizeof({name});\n"
    )


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: embed-radv-shaders.py VERT.spv FRAG.spv OUTPUT.h")
    output = pathlib.Path(sys.argv[3])
    text = "#pragma once\n#include <stdint.h>\n\n"
    text += module(pathlib.Path(sys.argv[1]), "radv_triangle_vert_spv") + "\n"
    text += module(pathlib.Path(sys.argv[2]), "radv_triangle_frag_spv")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="ascii", newline="\n")


if __name__ == "__main__":
    main()
