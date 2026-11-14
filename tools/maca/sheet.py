#!/usr/bin/env python3
"""Join screenshots side by side into one contact sheet: sheet.py out.png in1.png in2.png ..."""
import sys
from PIL import Image

out, paths = sys.argv[1], sys.argv[2:]
images = [Image.open(p).convert("RGB") for p in paths]
gap = 12
width = sum(i.width for i in images) + gap * (len(images) + 1)
height = max(i.height for i in images) + 2 * gap
sheet = Image.new("RGB", (width, height), (120, 120, 120))
x = gap
for image in images:
    sheet.paste(image, (x, gap))
    x += image.width + gap
sheet.save(out)
