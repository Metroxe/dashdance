#!/bin/zsh
# Packages the macOS build as "Melee Unlocked.app" (ad-hoc signed). Nothing from the
# game enters the bundle: only the executable and the vendored Slippi Sys folder.
# Usage: tools/package_macos_app.sh <build-dir> <output-dir>
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="${1:?build dir}"
OUT="${2:?output dir}"
VERSION="$(head -n1 "$ROOT/VERSION")"
APP="$OUT/Melee Unlocked.app"
EXE="$BUILD/port/melee_port_mac"
[[ -x "$EXE" ]] || { echo "missing $EXE; build target melee_port_mac first" >&2; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed "s/@VERSION@/$VERSION/g" "$ROOT/port/app/macos/Info.plist" > "$APP/Contents/Info.plist"
cp "$EXE" "$APP/Contents/MacOS/MeleeUnlocked"
cp -R "$ROOT/port/slippi_sys" "$APP/Contents/Resources/slippi_sys"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - --deep "$APP"
codesign --verify --deep --strict "$APP"
echo "packaged $APP ($VERSION)"
