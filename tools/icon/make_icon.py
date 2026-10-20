#!/usr/bin/env python3
"""Draws the placeholder app icon (1024x1024, no alpha). Requires Pillow."""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "Autoklipp", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main() -> int:
    top, bottom = (255, 138, 76), (196, 34, 104)
    image = Image.new("RGB", (SIZE, SIZE))
    pixels = image.load()
    for y in range(SIZE):
        for x in range(SIZE):
            t = min(1, max(0, (0.65 * y + 0.35 * x) / SIZE))
            pixels[x, y] = lerp(top, bottom, t)

    # Three stacked frames: the clips being cut together.
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    frames = [((300, 250, 820, 610), 70), ((250, 330, 770, 690), 130), ((200, 410, 720, 770), 255)]
    for box, alpha in frames:
        draw.rounded_rectangle(box, radius=48, fill=(255, 255, 255, alpha))
    # Play triangle in the front frame.
    cx, cy = 460, 590
    draw.polygon([(cx - 70, cy - 95), (cx - 70, cy + 95), (cx + 100, cy)], fill=(214, 54, 107, 255))
    shadow = layer.split()[3].filter(ImageFilter.GaussianBlur(18))
    shade = Image.new("RGBA", (SIZE, SIZE), (90, 10, 40, 0))
    shade.putalpha(shadow.point(lambda a: int(a * 0.35)))
    image.paste(shade, (0, 16), shade)
    image.paste(layer, (0, 0), layer)
    image.save(OUT, "PNG")
    print(f"wrote {os.path.normpath(OUT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
