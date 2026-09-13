#!/bin/zsh
# Packages the macOS build as "iSlippi.app" (ad-hoc signed). Nothing from the
# game enters the bundle: only the executable and the vendored Slippi Sys folder.
# Usage: tools/package_macos_app.sh <build-dir> <output-dir>
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="${1:?build dir}"
OUT="${2:?output dir}"
VERSION="$(head -n1 "$ROOT/VERSION")"
APP="$OUT/iSlippi.app"
EXE="$BUILD/port/melee_port_mac"
[[ -x "$EXE" ]] || { echo "missing $EXE; build target melee_port_mac first" >&2; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed "s/@VERSION@/$VERSION/g" "$ROOT/port/app/macos/Info.plist" > "$APP/Contents/Info.plist"
cp "$EXE" "$APP/Contents/MacOS/iSlippi"
cp -R "$ROOT/port/slippi_sys" "$APP/Contents/Resources/slippi_sys"
# App icon from the 1024px master (drawn by tools/make_icons.py; no game assets).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ROOT/port/app/icons/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) "$ROOT/port/app/icons/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - --deep "$APP"
codesign --verify --deep --strict "$APP"
echo "packaged $APP ($VERSION)"
