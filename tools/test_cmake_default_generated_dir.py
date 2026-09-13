"""Configure-only regression for CMake's default generated-game directory."""
import argparse
import json
import shlex
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmake", required=True)
    parser.add_argument("--ninja", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="melee-default-cmake-") as temporary:
        fixture = Path(temporary)
        build = fixture / "build"
        generated = build / "generated/guest"
        generated.mkdir(parents=True)
        # These files are configure-only placeholders, never compiled or run.
        (generated / "guest_sources.cmake").write_text("set(GUEST_SOURCES)\n")
        (generated / "function_names.cpp").write_text("// synthetic fixture\n")
        (generated / "gecko_data.cpp").write_text("// synthetic fixture\n")
        (build / "port-inputs.json").write_text(json.dumps({"configure_only_fixture": True}))
        decomp = fixture / "decomp"
        inputs = decomp / "src/sysdolphin/baselib"
        inputs.mkdir(parents=True)
        for name in ("fobj.c", "fobj.h", "spline.c"):
            (inputs / name).write_text("// synthetic configure-only input\n")
        result = subprocess.run([args.cmake, "-S", str(ROOT), "-B", str(build), "-G", "Ninja",
            "-DCMAKE_MAKE_PROGRAM=" + args.ninja, "-DMELEE_DECOMP_ROOT=" + str(decomp),
            "-DMELEE_BUILD_PORT_HEADLESS=ON", "-DMELEE_BUILD_EXPERIMENTAL_PORT=OFF"],
            capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        # Ask Ninja for the generated command; this does not execute the target.
        commands = subprocess.check_output([args.ninja, "-C", str(build), "-t", "commands",
                                            "port_verify_generated"], text=True)
        argv = shlex.split(commands)
        selected = argv[argv.index("--generated-dir") + 1]
        if Path(selected).resolve() != generated.resolve():
            raise AssertionError("default generated path was not passed to verifier: " + commands)
        if "MELEE_PORT_GENERATED_DIR:PATH=" + str(generated) not in (build / "CMakeCache.txt").read_text():
            raise AssertionError("CMake cache does not contain the expected default generated directory")
    print("direct default headless configure passes actual generated directory to verifier")


if __name__ == "__main__":
    main()
