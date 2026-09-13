#!/usr/bin/env python3
"""Draws the app icon (no game assets): an indigo gradient with a white ring and core.
Writes port/app/icons/AppIcon-1024.png plus the iOS sizes; macOS .icns is built by
tools/package_macos_app.sh with iconutil."""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter

out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "port", "app", "icons")
os.makedirs(out_dir, exist_ok=True)
S = 1024
img = Image.new("RGB", (S, S))
px = img.load()
for y in range(S):
    for x in range(S):
        t = (x + y) / (2 * S)
        r = 0.16 + (0.04 - 0.16) * t; g = 0.10 + (0.03 - 0.10) * t; b = 0.40 + (0.12 - 0.40) * t
        px[x, y] = (int(r * 255), int(g * 255), int(b * 255))
# soft violet glow top-left
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).ellipse((-200, -200, 620, 620), fill=140)
glow = glow.filter(ImageFilter.GaussianBlur(160))
img = Image.composite(Image.new("RGB", (S, S), (110, 80, 230)), img, glow)
# ring + core with a drop shadow
shadow = Image.new("L", (S, S), 0)
d = ImageDraw.Draw(shadow)
d.ellipse((212, 232, 812, 832), fill=255)
shadow = shadow.filter(ImageFilter.GaussianBlur(40))
img = Image.composite(Image.new("RGB", (S, S), (10, 6, 30)), img, shadow.point(lambda v: v * 0.6))
mark = Image.new("L", (S, S), 0)
d = ImageDraw.Draw(mark)
d.ellipse((212, 212, 812, 812), fill=255)
d.ellipse((292, 292, 732, 732), fill=0)
d.ellipse((392, 392, 632, 632), fill=255)
# a diagonal cut through the ring (motion)
d.polygon([(150, 560), (874, 400), (874, 470), (150, 630)], fill=0)
mark = mark.filter(ImageFilter.GaussianBlur(1.2))
img = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), img, mark)
img.save(os.path.join(out_dir, "AppIcon-1024.png"))
for name, size in [("AppIcon60x60@2x", 120), ("AppIcon60x60@3x", 180), ("AppIcon76x76@2x", 152), ("AppIcon83.5x83.5@2x", 167)]:
    img.resize((size, size), Image.LANCZOS).save(os.path.join(out_dir, name + ".png"))
print("icons written to", out_dir)
