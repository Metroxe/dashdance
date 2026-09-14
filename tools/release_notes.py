#!/usr/bin/env python3
"""Release notes from git history since the previous tag, in the player's words: one bullet per change
they can notice (features, fixes, performance), skipping internal work (build, CI, refactors, docs).
Each bullet keeps the commit's own first line, lightly cleaned; edit the result before publishing."""
import re, subprocess
def git(*a): return subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout.strip()
version = open("VERSION").read().split()[0]
tags = [t for t in git("tag", "--sort=-v:refname").splitlines() if t.startswith("v")]
prev = tags[0] if tags and tags[0] != f"v{version}" else (tags[1] if len(tags) > 1 else "")
rng = f"{prev}..HEAD" if prev else "HEAD"
lines = git("log", "--no-merges", "--pretty=%s", rng).splitlines()
internal = re.compile(r"^(ci|build|chore|refactor|docs?|readme|test|tests|memory)\b|README|CLAUDE\.md|\.github|gitignore|typo", re.I)
bullets = []
for l in lines:
    if internal.search(l): continue
    l = re.sub(r"^\w+(\(.*?\))?:\s*", "", l).strip().rstrip(".")
    if l and l not in bullets: bullets.append(l[0].upper() + l[1:])
print(f"## Dashdance {version}\n")
print(f"Changes since {prev}:" if prev else "First release:")
print()
for b in bullets[:12]: print(f"- {b}")
print("\nYou need your own Super Smash Bros. Melee NTSC 1.02 disc image. iPhone/iPad: install the IPA with AltStore, SideStore or Sideloadly.")
