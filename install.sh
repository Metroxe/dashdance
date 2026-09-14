#!/bin/zsh
# Dashdance installer for players. Paste this into Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/TheAndersMadsen/islippi/main/install.sh | zsh
#
# It checks the Mac, gets Apple's developer tools if needed, downloads (or updates) Dashdance into ~/Dashdance, asks for your
# Melee disc image, builds the app from it on this Mac, puts Dashdance in Applications and opens it. Run it again to update.
set -euo pipefail
for _v in ISO DECOMP JOBS TEAM UDID NO_OPEN DIR; do eval ": \${DASHDANCE_$_v:=\${ISLIPPI_$_v:-}}"; done   # the earlier ISLIPPI_* names still work
yellow() { printf '\n\033[1;33m%s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31m%s\033[0m\n' "$1" >&2; exit 1; }
DIR="${DASHDANCE_DIR:-$HOME/Dashdance}"
[[ -d "$HOME/iSlippi/.git" && ! -e "$DIR" ]] && mv "$HOME/iSlippi" "$DIR"   # a download from before the rename

[[ "$(uname)" == "Darwin" && "$(uname -m)" == "arm64" ]] || fail "Dashdance needs a Mac with Apple silicon (M1 or newer)."

if ! xcode-select -p >/dev/null 2>&1; then
  yellow "Dashdance needs Apple's free developer tools."
  xcode-select --install || true
  echo "A window opened to install them. When it finishes, paste the same install line into Terminal again."
  exit 0
fi

if [[ -d "$DIR/.git" ]]; then
  yellow "Updating Dashdance in $DIR"
  git -C "$DIR" pull --ff-only --quiet
else
  yellow "Downloading Dashdance into $DIR"
  git clone --depth 1 --quiet https://github.com/TheAndersMadsen/islippi.git "$DIR"
fi

ISO="${1:-${DASHDANCE_ISO:-}}"
[[ -z "$ISO" && -f "$DIR/.disc-path" ]] && ISO="$(cat "$DIR/.disc-path")"
while [[ -z "$ISO" || ! -f "$ISO" ]]; do
  yellow "Drag your Super Smash Bros. Melee disc image (NTSC 1.02, .iso or .gcm) into this window, then press Return:"
  IFS= read -r ISO < /dev/tty
  # A dragged path arrives quoted or with escaped spaces and a trailing space.
  ISO="$(print -r -- "$ISO" | sed -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//" -e 's/\\\(.\)/\1/g')"
  [[ -f "$ISO" ]] || echo "That file was not found. Try dragging it in again."
done
print -r -- "$ISO" > "$DIR/.disc-path"

yellow "Building Dashdance from your disc (about ten to fifteen minutes the first time)"
DASHDANCE_NO_OPEN=1 "$DIR/setup.sh" "$ISO" < /dev/tty   # setup may run Homebrew's installer, which needs the terminal to ask for your password

DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
rm -rf "$DEST/Dashdance.app" "$DEST/iSlippi.app"   # also the app's earlier name
ditto "$DIR/dist/Dashdance.app" "$DEST/Dashdance.app"
yellow "Dashdance is in $DEST. Opening it now."
open "$DEST/Dashdance.app" --args --iso "$ISO" --choose-disc
