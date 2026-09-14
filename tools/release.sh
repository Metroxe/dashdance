#!/bin/zsh
# Builds every release artifact and publishes a GitHub release for the current VERSION.
#
#   tools/release.sh /path/to/melee.iso            build dist/iSlippi-<v>.dmg, dist/iSlippi-<v>.ipa, checksums, notes
#   tools/release.sh /path/to/melee.iso --publish  ...and create a DRAFT GitHub release with them (gh CLI)
#
# READ THIS FIRST. The app contains the translated game. A release on a public repository distributes
# Nintendo's code to everyone, which is illegal and against the Slippi team's wishes. Publish only from a
# private repository (or keep the assets local). The script therefore refuses --publish unless the
# repository is private, and always creates a draft.
set -euo pipefail
ROOT="${0:A:h:h}"
ISO="${ISLIPPI_ISO:-}"; PUBLISH=0
for arg in "$@"; do case "$arg" in --publish) PUBLISH=1;; --*) echo "unknown option $arg" >&2; exit 2;; *) ISO="$arg";; esac; done
VERSION="$(head -n1 "$ROOT/VERSION")"
TAG="v$VERSION"
step() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }
[[ -n "$ISO" && -f "$ISO" ]] || fail "give the path to your Melee NTSC 1.02 disc image"

step "macOS app ($TAG)"
"$ROOT/setup.sh" "$ISO" --mac >/dev/null
pkill -f "dist/iSlippi.app/Contents/MacOS/iSlippi" 2>/dev/null || true
step "DMG"
DMG="$ROOT/dist/iSlippi-$VERSION.dmg"; rm -f "$DMG"
STAGE="$(mktemp -d)"; cp -R "$ROOT/dist/iSlippi.app" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "iSlippi $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
step "iPhone/iPad IPA (ad-hoc, for sideloading)"
"$ROOT/setup.sh" "$ISO" --device >/dev/null
mv -f "$ROOT/dist/iSlippi.ipa" "$ROOT/dist/iSlippi-$VERSION.ipa"
step "Checksums and notes"
(cd "$ROOT/dist" && shasum -a 256 "iSlippi-$VERSION.dmg" "iSlippi-$VERSION.ipa" > "SHA256SUMS-$VERSION.txt" && cat "SHA256SUMS-$VERSION.txt")
python3 "$ROOT/tools/release_notes.py" > "$ROOT/dist/RELEASE_NOTES-$VERSION.md"
echo; cat "$ROOT/dist/RELEASE_NOTES-$VERSION.md"
if (( PUBLISH )); then
  step "Publishing a draft release"
  command -v gh >/dev/null || fail "install the GitHub CLI (brew install gh) and run gh auth login"
  VIS="$(gh repo view --json visibility -q .visibility 2>/dev/null || echo unknown)"
  [[ "$VIS" == "PRIVATE" ]] || fail "this repository is $VIS. Releases with the built app must stay private (they contain the translated game). Fork privately, or skip --publish."
  git -C "$ROOT" tag -f "$TAG" >/dev/null && git -C "$ROOT" push -q --force origin "$TAG"
  gh release create "$TAG" --draft --title "iSlippi $VERSION" --notes-file "$ROOT/dist/RELEASE_NOTES-$VERSION.md" \
    "$ROOT/dist/iSlippi-$VERSION.dmg" "$ROOT/dist/iSlippi-$VERSION.ipa" "$ROOT/dist/SHA256SUMS-$VERSION.txt"
  echo "Draft release $TAG created. Review it on GitHub, then publish it there."
fi
