#!/usr/bin/env python3
"""Draws the flat fallback app icons (no game or Slippi assets): the Dashdance mark from the Icon Composer bundle
(port/app/icons/AppIcon.icon/Assets/glyph.png, drawn from port/app/icons/dashdance_mark.svg) on the icon's violet
gradient. Writes port/app/icons/AppIcon-1024.png plus the iOS sizes. The Liquid Glass icon itself is compiled from the
Icon Composer bundle by actool; these PNGs are for toolchains without it."""
import os
from PIL import Image, ImageDraw, ImageFilter

icons = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "port", "app", "icons")
S = 1024
top, bottom = (125, 92, 255), (40, 23, 107)   # matches the fill in AppIcon.icon/icon.json
bg = Image.new("RGB", (S, S))
px = bg.load()
for y in range(S):
    for x in range(S):
        t = (x * 0.35 + y * 0.65) / S
        px[x, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).ellipse((-240, -260, 640, 560), fill=120)
bg = Image.composite(Image.new("RGB", (S, S), (190, 170, 255)), bg, glow.filter(ImageFilter.GaussianBlur(170)))
mark = Image.open(os.path.join(icons, "AppIcon.icon", "Assets", "glyph.png")).convert("RGBA").resize((S, S), Image.LANCZOS)
icon = bg.convert("RGBA")
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.paste((10, 5, 40, 150), (0, 18), mark.split()[3])
icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(26)))
icon = Image.alpha_composite(icon, mark).convert("RGB")
icon.save(os.path.join(icons, "AppIcon-1024.png"))
for name, size in [("AppIcon60x60@2x", 120), ("AppIcon60x60@3x", 180), ("AppIcon76x76@2x", 152), ("AppIcon83.5x83.5@2x", 167)]:
    icon.resize((size, size), Image.LANCZOS).save(os.path.join(icons, name + ".png"))
print("icons written to", icons)
