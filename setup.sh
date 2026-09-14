#!/bin/zsh
# iSlippi one-command setup. Installs the build tools, fetches the doldecomp/melee checkout the
# port needs, pulls main.dol out of your own disc image, builds, packages and opens the app.
#
#   ./setup.sh /path/to/melee.iso            macOS app (default)
#   ./setup.sh /path/to/melee.iso --ios      iPad/iPhone Simulator app (needs Xcode)
#   ./setup.sh /path/to/melee.iso --visionos Vision Pro Simulator app (needs Xcode)
#
# Environment overrides: ISLIPPI_ISO (disc path), ISLIPPI_DECOMP (existing doldecomp/melee checkout),
# ISLIPPI_JOBS (parallel jobs). Re-running is safe: every step skips work that is already done.
set -euo pipefail
ROOT="${0:A:h}"
ISO="${1:-${ISLIPPI_ISO:-}}"
TARGET="mac"
for arg in "$@"; do case "$arg" in --ios) TARGET=ios;; --visionos) TARGET=visionos;; --mac) TARGET=mac;; esac; done
step() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "iSlippi builds on macOS (Apple silicon). See README.md for other platforms."
[[ "$(uname -m)" == "arm64" ]] || fail "an Apple silicon Mac is required."
[[ -n "$ISO" ]] || fail "give the path to your Super Smash Bros. Melee NTSC 1.02 disc image: ./setup.sh /path/to/melee.iso"
[[ -f "$ISO" ]] || fail "disc image not found: $ISO"

step "Xcode tools"
if [[ "$TARGET" == "mac" ]]; then
  xcode-select -p >/dev/null 2>&1 || { echo "installing the Command Line Tools (a dialog will open)…"; xcode-select --install || true; fail "re-run ./setup.sh once the Command Line Tools have finished installing."; }
else
  [[ -d /Applications/Xcode.app ]] || fail "the iPad and Vision Pro builds need the full Xcode from the App Store."
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

step "Homebrew packages (cmake ninja python libusb)"
if ! command -v brew >/dev/null; then
  echo "Homebrew is not installed; installing it (https://brew.sh)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
for pkg in cmake ninja python libusb; do brew list --versions "$pkg" >/dev/null 2>&1 || brew install "$pkg"; done
python3 -c "import PIL" 2>/dev/null || python3 -m pip install --quiet --user pillow 2>/dev/null || true

step "doldecomp/melee (function names and animation helpers the port reads at build time)"
DECOMP="${ISLIPPI_DECOMP:-$ROOT/deps/melee}"
if [[ ! -d "$DECOMP/src" ]]; then
  mkdir -p "$ROOT/deps"
  git clone --depth 1 https://github.com/doldecomp/melee.git "$DECOMP"
fi

step "main.dol from your disc"
mkdir -p "$ROOT/deps/disc"
DOL="$ROOT/deps/disc/main.dol"
[[ -f "$DOL" ]] || python3 "$ROOT/tools/extract_dol.py" "$ISO" "$DOL"

step "Aurora (pinned window/renderer dependency)"
[[ -d "$ROOT/build/deps/aurora" ]] || "$ROOT/tools/bootstrap_aurora.sh"

JOBS="${ISLIPPI_JOBS:-$(sysctl -n hw.ncpu)}"
case "$TARGET" in
  mac)
    BUILD="$ROOT/build/mac"
    step "Generating the port (this translates the game once; a few minutes)"
    python3 "$ROOT/tools/bootstrap_port.py" --decomp-root "$DECOMP" --dol "$DOL" --build-dir "$BUILD" --gct-base 0x8065CC80 --macos-arch arm64 --stage generate
    step "Building the macOS app"
    cmake -S "$ROOT" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
      -DMELEE_DECOMP_ROOT="$DECOMP" -DMELEE_DOL_PATH="$DOL" -DMELEE_PORT_GENERATED_DIR="$BUILD/generated/guest" \
      -DMELEE_BUILD_PORT_TESTS=OFF -DMELEE_BUILD_PORT_HEADLESS=OFF -DMELEE_BUILD_PORT_METAL=ON >/dev/null
    cmake --build "$BUILD" --target melee_port_mac --parallel "$JOBS"
    step "Packaging iSlippi.app"
    "$ROOT/tools/package_macos_app.sh" "$BUILD" "$ROOT/dist"
    echo
    echo "Done. Opening dist/iSlippi.app — choose your disc in the dashboard the first time (it is remembered)."
    open "$ROOT/dist/iSlippi.app" --args --iso "$ISO" --choose-disc
    ;;
  ios|visionos)
    if [[ "$TARGET" == "ios" ]]; then BUILD="$ROOT/build/ios-sim"; SYS=iOS; SDK=iphonesimulator; MIN=17.0; else BUILD="$ROOT/build/visionos-sim"; SYS=visionOS; SDK=xrsimulator; MIN=1.0; fi
    step "Generating the port"
    python3 "$ROOT/tools/bootstrap_port.py" --decomp-root "$DECOMP" --dol "$DOL" --build-dir "$BUILD" --gct-base 0x8065CC80 --macos-arch arm64 --stage generate
    step "Building the $SYS Simulator app"
    cmake -S "$ROOT" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_SYSTEM_NAME=$SYS -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_SYSROOT=$SDK -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN \
      -DMELEE_DECOMP_ROOT="$DECOMP" -DMELEE_DOL_PATH="$DOL" -DMELEE_PORT_GENERATED_DIR="$BUILD/generated/guest" \
      -DMELEE_BUILD_PORT_TESTS=OFF -DMELEE_BUILD_PORT_HEADLESS=OFF -DMELEE_BUILD_PORT_METAL=ON >/dev/null
    cmake --build "$BUILD" --target melee_port_mac --parallel "$JOBS"
    APP="$BUILD/port/iSlippi.app"
    step "Installing on a booted Simulator (boot one in Xcode › Open Developer Tool › Simulator first)"
    if xcrun simctl list devices booted | grep -q Booted; then
      xcrun simctl install booted "$APP"
      BID=app.islippi.ios
      C="$(xcrun simctl get_app_container booted $BID data)"; mkdir -p "$C/Documents"; cp "$ISO" "$C/Documents/melee.iso"
      xcrun simctl launch booted $BID >/dev/null && echo "Launched. Touch controls are on by default; pair a controller in the Simulator's I/O menu."
    else
      echo "No Simulator is booted. Boot one, then: xcrun simctl install booted \"$APP\" and copy your disc into the app's Documents folder (Files app)."
    fi
    ;;
esac
