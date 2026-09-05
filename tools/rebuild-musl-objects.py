"""Recompile upstream musl objects without editing their ELF symbol tables."""
import concurrent.futures
import pathlib
import shlex
import subprocess
import sys


def main():
    build = pathlib.Path(sys.argv[1]).resolve()
    commands = subprocess.check_output(
        ["make", "-Bn", "lib/libc.so"], cwd=build, text=True
    ).replace("\\\n", " ")
    jobs = []
    for line in commands.splitlines():
        if "zig-cc-wrapper.py" in line and " -c -o " in line:
            command = shlex.split(line)
            command[0] = sys.executable
            jobs.append(command)
    if not jobs:
        raise RuntimeError("No upstream object compilation commands found")

    def compile_object(command):
        result = subprocess.run(command, cwd=build, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for count, _ in enumerate(pool.map(compile_object, jobs), 1):
            if count % 100 == 0 or count == len(jobs):
                print(f"musl upstream objects: {count}/{len(jobs)}", flush=True)


if __name__ == "__main__":
    main()
