import pathlib
import shlex
import subprocess
import sys
import tempfile


def quote_response(argument: str) -> str:
    return '"' + argument.replace('\\', '\\\\').replace('"', '\\"') + '"\n'


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: link-musl-shared.py BUILD_DIR ZIG WRAPPER")
    build = pathlib.Path(sys.argv[1]).resolve()
    zig = pathlib.Path(sys.argv[2]).resolve()
    wrapper = pathlib.Path(sys.argv[3]).resolve()
    dry_run = subprocess.run(
        ["make", "-Bn", "lib/libc.so"], cwd=build, check=True,
        text=True, stdout=subprocess.PIPE,
    ).stdout.replace("\\\n", " ")
    link_line = next(
        line for line in dry_run.splitlines()
        if " -nostdlib -shared " in line and " -o lib/libc.so " in line
    )
    parsed = shlex.split(link_line, posix=True)
    arguments = parsed[parsed.index("-std=c99"):]
    # Zig interprets -lgcc_eh as a request for libunwind and target libc.
    # musl provides its own runtime; do not pull the toolchain stub DSO in.
    arguments = [argument for argument in arguments if argument not in {"-lgcc", "-lgcc_eh"}]
    compile_line = next(line for line in dry_run.splitlines()
                        if " -c -o " in line and "src/env/__init_tls.c" in line)
    compile_args = shlex.split(compile_line)
    compile_args = compile_args[compile_args.index("-std=c99"):compile_args.index("-c")]
    bootstrap = build / "obj/csos-bootstrap.o"
    subprocess.run([str(zig), "cc", "-target", "x86_64-linux-musl",
                    *compile_args, "-c", str(wrapper.parent / "musl-csos-bootstrap.c"),
                    "-o", str(bootstrap)], cwd=build, check=True)
    arguments.append(str(bootstrap))
    builtins = build.parent / "llvm-project-21.1.0/compiler-rt/lib/builtins"
    revision = subprocess.check_output(
        ["git", "-C", str(builtins), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != "3623fe661ae35c6c80ac221f14d85be76aa870f1":
        raise RuntimeError("compiler-rt revision mismatch")
    for name in ("mulsc3", "muldc3", "mulxc3"):
        output = build / "obj" / (name + ".o")
        subprocess.run([
            str(zig), "cc", "-target", "x86_64-linux-musl", "-O2",
            "-fPIC", "-fvisibility=hidden", "-c", str(builtins / (name + ".c")),
            "-o", str(output),
        ], check=True)
        arguments.append(str(output))
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", suffix=".rsp", delete=False
    ) as response:
        response_path = pathlib.Path(response.name)
        for argument in [
            "-target", "x86_64-linux-musl", "-Wl,-soname,libc.so",
            *arguments
        ]:
            response.write(quote_response(argument))
    try:
        result = subprocess.run(
            [sys.executable, str(wrapper), str(zig), "cc", "@" + str(response_path)],
            cwd=build,
        )
        if result.returncode:
            return result.returncode
        return subprocess.run([
            sys.executable, str(wrapper.parent / "audit-musl-runtime.py"),
            str(build / "lib/libc.so"),
        ]).returncode
    finally:
        response_path.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
