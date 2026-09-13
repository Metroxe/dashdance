# Portable build foundation

The macOS branch starts at `Hero88go/melee-unlocked` commit
`b8360b15f6a55bcb6433e6e386bebd0e6b39428d`. Its translated gameplay and Slippi code
tables are retained. The current `melee_port_headless` target is an offline
diagnostic milestone. A successful build does not establish Metal rendering,
audio device support, controller support, online interoperability, AOT-only
coverage, or gameplay parity. Windows retains the existing
`MELEE_BUILD_EXPERIMENTAL_PORT` target and D3D12 application.

## Explicit inputs

`tools/port_source_pins.json` records the exact upstream/decomp commits, three
animation source hashes, symbol-map hash, and vanilla NTSC 1.02 DOL SHA1. Provide
a local decomp checkout at `05a1394faea2aac458e4bdd030621d8a5631ae62` and a legally
obtained DOL matching `08e0bf20134dfcb260699671004527b2d6bb1a45`. Only the listed
source files and DOL are read. The bootstrap verifies each input before generation;
unrelated decomp checkout changes are left alone.

No ISO extraction, source checkout copying, symlink setup, global environment
changes, profile discovery, or game launch is part of this build procedure.
Generated game C++ remains private under the ignored `build/` directory. Do not
commit or distribute it. Local `port-inputs.json` records exact inputs, generator
hashes, generated file hashes, and the command used. Executables bind an immutable
manifest under `build/<profile>/manifests/<sha256>.json`; `port-inputs.json` is the
convenience copy for the latest generation. The complete 20-file runtime Slippi Sys
tree is checked against the upstream Git commit, hashed, and checked again after
generation. Sys symlinks, inventory drift, and changed bytes are rejected.

Before compilation, the build verifies the actual CMake source/decomp/generated
paths, every recorded source, generated game file and animation adapter, the DOL,
and all runtime Sys assets. It repeats those checks after linking and writes
`melee_port_headless.verified.json` with the artifact, immutable manifest, and
compiler-command hashes. The sidecar is marked unverified before relinking and
on verification failure. Runtime launch manifests provide the separate execution
evidence; a build sidecar does not establish gameplay acceptance.

## Build portable unit tests

Python 3.11+, CMake, a C++17 compiler, and Ninja are needed. These tests do not need
generated game translation units. Assertions remain enabled for Release tests.

```sh
cmake -S . -B build/portable-tests -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DMELEE_DECOMP_ROOT=/absolute/path/to/decomp \
  -DMELEE_BUILD_PORT_TESTS=ON
cmake --build build/portable-tests --parallel 4
ctest --test-dir build/portable-tests --output-on-failure
```

Add `-DMELEE_BUILD_PORT_TRANSPORT_TESTS=ON` when explicitly running the real Slippi
transport test. It binds both endpoints to `127.0.0.1`, uses ephemeral ports and
synthetic input packets, and does not construct user, matchmaking or reporting
services. This option never links a transport into the headless executable.
The bootstrap exposes the same opt-in as `--transport-tests`.

## Generate and compile the offline executable

```sh
python3 tools/bootstrap_port.py \
  --decomp-root /absolute/path/to/decomp \
  --dol /absolute/path/to/main.dol \
  --build-dir build/mac-headless \
  --gct-base 0x8065CC80 \
  --macos-arch arm64 \
  --jobs 4
```

The GCT address is the build profile in the pinned upstream README. It is an
explicit assumption, and the actual guest load address must agree during runtime
validation. `--no-slippi` instead requests an explicit vanilla-only diagnostic;
the bootstrap never silently omits C0 caves by defaulting the address to zero.
Use `--stage generate` or `--stage configure` to stop before compilation.
`--no-slippi` changes guest patch generation; it still binds the same complete
runtime Sys asset tree required by launch validation.

The headless runtime uses an explicit source list. Win32 windowing, WASAPI,
D3D12, Streamline, ImGui's Windows backends, ENet sockets, and HTTP reporting are
outside this executable. Its offline service boundary rejects online requests.
GX FIFO processing and guest interrupt delivery remain in the runtime, even
without a graphics device.

Clang gameplay/runtime code uses strict floating-point evaluation and disables
implicit FP contraction. GCC uses rounding-aware compilation. This is a required
compiler profile, not evidence of cross-architecture numeric equivalence. Numeric
parity and dispatch/interpreter coverage need their own measured gates.

`MELEE_DECOMP_ROOT`, `MELEE_DOL_PATH`, and `MELEE_PORT_GENERATED_DIR` are explicit
CMake cache paths. Direct Windows builds can keep their existing generated-code
location or point `MELEE_PORT_GENERATED_DIR` at a local build directory. The new
portable options default off, so the Windows application remains opt-in as before.
