# iSlippi — guide for coding agents and new contributors

iSlippi is a native macOS / iPadOS / iOS / visionOS client for Super Smash Bros. Melee with Slippi
Online, built by statically recompiling the game's PowerPC code to C++ and running it on a host
runtime with a Metal renderer. Read this file first; it tells you how the tree is laid out, how to
build, and the rules that are not obvious from the code.

## One-command setup

```bash
./setup.sh /path/to/melee.iso            # macOS app -> dist/iSlippi.app
./setup.sh /path/to/melee.iso --ios      # iPad/iPhone Simulator app (needs Xcode)
./setup.sh /path/to/melee.iso --visionos # Vision Pro Simulator app (needs Xcode)
./setup.sh /path/to/melee.iso --device   # dist/iSlippi.ipa for AltStore/SideStore/Sideloadly; --team auto signs and installs over USB
```

There is no store or public-release distribution and there must not be: the built app contains the
translated game. `tools/release.sh` and `.github/workflows/release.yml` build DMG/IPA release assets for a
private fork only (both refuse public repositories).

The script installs Homebrew packages (cmake ninja python), clones doldecomp/melee into
`deps/melee`, extracts `main.dol` from the disc (`tools/extract_dol.py`), fetches the pinned Aurora
dependency, generates the port, builds, packages and opens the app. Nothing from the game is
committed; the disc stays where it is.

## Layout

| Path | What lives there |
|---|---|
| `port/app/main_mac.cpp` | The app entry point for all Apple platforms: options, launcher/dashboard, game loop start. |
| `port/app/ios/`, `port/app/macos/` | Info.plist templates. |
| `port/app/icons/AppIcon.icon` | Icon Composer bundle (Slippi mark as a glass layer). `tools/package_macos_app.sh` and CMake compile it with `actool`. |
| `port/runtime/host/` | Host services: window + input (`window_sdl.cpp`), dashboards (`mac_launcher.mm`, `ios_launcher.mm`), controller mapping (`input_config.*`), dashboard model (`dashboard.*`), retrace/timing (`host.cpp`), touch overlay (`overlay.*`), GameCube adapter (`gc_adapter_iokit.cpp` on macOS: IOKit with a 1 ms pipe policy; `gc_adapter_libusb.cpp` elsewhere), controller report-rate measurement (`controller_rate.mm`). |
| `port/runtime/gx/` | The GX (GameCube GPU) translation and the Metal renderer (`gx_metal.mm`, `gx_msl.cpp`). |
| `port/runtime/hle/` | High-level emulation of the GameCube SDK the game calls (disc, pads, audio, memory cards) and Slippi's EXI device, login (`slippi_login.*`) and replay parsing (`slippi_history.*`). |
| `port/runtime/ppc/` | Guest CPU context, memory, interpreter fallback. |
| `port/recomp/` | The recompiler configuration; `hle_list.txt` names the guest functions replaced by host code. |
| `port/slippi_sys/` | Vendored Slippi game files (Sys folder). |
| `tools/` | Build helpers: `bootstrap_port.py` (generate/configure/build), `extract_dol.py`, `package_macos_app.sh`, `make_icons.py`. |
| `docs/` | Longer notes and README images. |

## Build rules that bite

- **Provenance gate.** Any edit under `port/` invalidates the generated manifest. Before building run
  `python3 tools/bootstrap_port.py --decomp-root <decomp> --dol <main.dol> --build-dir <build-dir> --gct-base 0x8065CC80 --macos-arch arm64 --stage generate`
  (or `./setup.sh`, which does it). Otherwise `port_verify_generated` fails with a one-line error.
- **Toolchains.** macOS builds run with the Command Line Tools (`unset DEVELOPER_DIR`). iOS and
  visionOS builds need `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Mixing
  them produces precompiled-header mismatches.
- **HLE hooks are matched by symbol name.** A name missing from `port/recomp/hle_list.txt` is silently
  recompiled instead of hooked (this is how a `longjmp` bug once corrupted guest memory).
- **Never build while measuring performance**, and shut down Simulators first: both distort the
  per-frame numbers.

## Running and diagnosing

- `build/<dir>/port/melee_port_mac --help` lists every flag. Useful: `--iso`, `--fullscreen`,
  `--no-vsync`, `--window WxH`, `--offline`, `--profile-dir`, `--cache-dir`, `--log-file`.
- Every 60 frames the log has `[frame N] ... sim: X ms/frame (worst Y) | <cost slots>`; frames over
  16.7 ms log `sim frame N took ...` with the cost slots that explain it.
- `MELEE_METAL_LATENCY=1` logs XFB-copy-to-panel latency from Metal's presented timestamps and GPU
  time. `MELEE_METAL_COMPILE_LOG=1` logs every shader compile. `MELEE_RENDER_THREAD=0`,
  `MELEE_REALTIME=0`, `MELEE_METAL_SYNC_COMPILE=1` turn the render thread, real-time scheduling and
  background shader compilation off for A/B tests.
- `MELEE_DASHBOARD_SAMPLE=1` fills the dashboard with sample data; `MELEE_LAUNCHER_SCROLL=<pt>` starts
  it scrolled; `MELEE_MARK=<glyph.png>` shows the Slippi mark when running the bare binary.
- `MELEE_PAD_FILE=<file>` drives the game from a text file (one line per pad: `p=1 A sx=127`), which
  is how the scripted match tests work without a window in focus.
- On the Simulator, prefix environment variables with `SIMCTL_CHILD_` and pass them to
  `xcrun simctl launch`.

## Design rules

- Apple platform conventions first: Liquid Glass on macOS/iOS 26 (`NSGlassEffectView`, `UIGlassEffect`)
  with material fallbacks, glass buttons, SF Symbols, native controls with visible labels and values,
  haptics only for user actions, a real menu bar on the Mac. See README "Design".
- Melee's own grammar stays: angled yellow section headers, italic display type, dark blue grid.
- Colours and glass tints come from the small theme helpers at the top of each launcher file; do not
  scatter literal colours.
- Keep the simulation thread free of anything that can block (display, GPU, disk, shader compiles).

## Verification checklist for a change

1. Build the target you touched (macOS at least; iOS if you touched shared UI or Metal).
2. Run a scripted match and confirm `late` frames stay at zero (see the scripts described in
   `docs/PERFORMANCE.md`).
3. For UI: capture the dashboard (`MELEE_DASHBOARD_SAMPLE=1`) and look at it.
4. Commit with a message that says what changed for the player and why.
