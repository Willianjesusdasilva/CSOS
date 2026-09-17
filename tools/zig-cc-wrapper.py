import pathlib
import re
import subprocess
import sys
import tempfile


def main() -> int:
    if len(sys.argv) < 3:
        raise SystemExit("usage: zig-cc-wrapper.py ZIG MODE [ARGS...]")
    command = sys.argv[1:3]
    temporaries = []
    try:
        arguments = sys.argv[3:]
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            # Meson emits version-script as two linker arguments on Windows.
            # Zig/LLD requires the option and path in one -Wl argument.
            if argument == "-Wl,--version-script" and index + 1 < len(arguments):
                command.append("-Wl,--version-script=" + arguments[index + 1])
                index += 2
                continue
            # Autoconf under Git/MSYS translates /dev/null to the Windows
            # device name "nul". Zig/LLD treats it as an ordinary output path
            # and fails, so give probes a disposable real file instead.
            if argument.lower() in {"nul", "/dev/null"}:
                handle = tempfile.NamedTemporaryFile(delete=False)
                handle.close()
                temporary = pathlib.Path(handle.name)
                temporaries.append(temporary)
                command.append(str(temporary))
                continue
            if not argument.startswith("@"):
                command.append(argument)
                index += 1
                continue
            source = pathlib.Path(argument[1:])
            contents = source.read_text(encoding="utf-8")
            # Zig requires the GNU linker option and its value in one -Wl
            # argument. Meson emits them separately for version scripts.
            contents, count = re.subn(
                r'"?-Wl,--version-script"?\s+"([^"]+)"',
                lambda match: f'"-Wl,--version-script={match.group(1)}"',
                contents,
            )
            # Meson running on Windows mistakes target dependency directories
            # for runtime locations. Never embed a host drive path in Linux ELF.
            contents, rpath_count = re.subn(
                r'\s+"-Wl,-rpath,[A-Za-z]:/[^"]+"', "", contents
            )
            count += rpath_count
            if not count:
                command.append(argument)
                index += 1
                continue
            handle = tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", suffix=".rsp", delete=False
            )
            temporary = pathlib.Path(handle.name)
            temporaries.append(temporary)
            with handle:
                handle.write(contents)
            command.append("@" + str(temporary))
            index += 1
        return subprocess.run(command).returncode
    finally:
        for temporary in temporaries:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
