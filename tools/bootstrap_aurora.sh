#!/bin/zsh
# Clones the pinned Aurora revision into build/deps/aurora and applies the local patches.
# Usage: tools/bootstrap_aurora.sh [checkout-dir]
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="${1:-$ROOT/build/deps/aurora}"
REV=749d6ee7a22bdfab78c8ece9047bca5d79aa72ca
if [[ ! -d "$DIR/.git" ]]; then
  git clone https://github.com/encounter/aurora.git "$DIR"
fi
git -C "$DIR" checkout --quiet --detach "$REV"
git -C "$DIR" checkout --quiet -- .
for patch in "$ROOT"/port/patches/aurora-*.patch; do
  git -C "$DIR" apply "$patch"
  echo "applied ${patch:t}"
done
echo "Aurora $REV ready at $DIR"
