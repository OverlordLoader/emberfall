#!/usr/bin/env python3
"""Generate the Emberfall Kingdom app icon set into Assets.xcassets/AppIcon.appiconset.

The icon shows a black citadel silhouette with ember-orange glowing windows
rising from a furnace glow, a sliver of frost-blue at the top edge (the
enemy at the gates). Pure PIL, no assets.
"""
from PIL import Image, ImageDraw, ImageFilter
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
OUT = HERE / "Emberfall" / "Assets.xcassets" / "AppIcon.appiconset"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def draw_icon(size):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    # Background: near-black top -> deep ember brown bottom.
    top, bottom = (16, 14, 12), (46, 22, 10)
    for y in range(size):
        d.line([(0, y), (size, y)], fill=lerp(top, bottom, y / size))

    # Frost sliver at the top edge.
    frost = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frost)
    fd.rectangle([0, 0, size, size * 0.10], fill=(125, 211, 252, 90))
    frost = frost.filter(ImageFilter.GaussianBlur(size // 24))
    img.paste(frost, (0, 0), frost)

    # Furnace glow near the bottom.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([size * 0.05, size * 0.55, size * 0.95, size * 1.12],
               fill=(255, 122, 41, 120))
    glow = glow.filter(ImageFilter.GaussianBlur(size // 8))
    img.paste(glow, (0, 0), glow)

    # Citadel silhouette: central keep + two side towers with battlements.
    sil = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sil)
    dark = (12, 8, 6, 255)
    cx = size / 2
    # Side towers
    for sx in (size * 0.20, size * 0.80):
        w = size * 0.16
        sd.rectangle([sx - w / 2, size * 0.38, sx + w / 2, size * 0.92], fill=dark)
        for i in range(3):  # battlements
            bx = sx - w / 2 + i * (w / 3)
            sd.rectangle([bx, size * 0.33, bx + w / 3 * 0.7, size * 0.38], fill=dark)
    # Central keep (taller)
    w = size * 0.30
    sd.rectangle([cx - w / 2, size * 0.26, cx + w / 2, size * 0.92], fill=dark)
    for i in range(4):
        bx = cx - w / 2 + i * (w / 4)
        sd.rectangle([bx, size * 0.21, bx + w / 4 * 0.7, size * 0.26], fill=dark)
    # Base wall connecting them
    sd.rectangle([size * 0.08, size * 0.62, size * 0.92, size * 0.92], fill=dark)
    sil = sil.filter(ImageFilter.GaussianBlur(max(1, size // 220)))
    img.paste(sil, (0, 0), sil)

    # Glowing ember windows.
    win = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    wd = ImageDraw.Draw(win)
    ember = (255, 150, 60, 255)
    for wy in (0.45, 0.55, 0.68):
        for wx in (0.38, 0.50, 0.62):
            r = size * 0.028
            wd.ellipse([size * wx - r, size * wy - r, size * wx + r, size * wy + r], fill=ember)
    for wx in (0.20, 0.80):
        r = size * 0.022
        wd.ellipse([size * wx - r, size * 0.52 - r, size * wx + r, size * 0.52 + r], fill=ember)
    win = win.filter(ImageFilter.GaussianBlur(max(1, size // 200)))
    img.paste(win, (0, 0), win)

    # Ember spark rising from the keep.
    spark = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    spd = ImageDraw.Draw(spark)
    spd.ellipse([cx - size * 0.05, size * 0.08, cx + size * 0.05, size * 0.18],
                fill=(255, 190, 100, 230))
    spark = spark.filter(ImageFilter.GaussianBlur(size // 40))
    img.paste(spark, (0, 0), spark)
    return img


SIZES = [
    ("Icon-20@2x.png", 40), ("Icon-20@3x.png", 60),
    ("Icon-29@2x.png", 58), ("Icon-29@3x.png", 87),
    ("Icon-40@2x.png", 80), ("Icon-40@3x.png", 120),
    ("Icon-60@2x.png", 120), ("Icon-60@3x.png", 180),
    ("Icon-1024.png", 1024),
]

CONTENTS = {
    "images": [
        {"filename": "Icon-20@2x.png", "idiom": "iphone", "scale": "2x", "size": "20x20"},
        {"filename": "Icon-20@3x.png", "idiom": "iphone", "scale": "3x", "size": "20x20"},
        {"filename": "Icon-29@2x.png", "idiom": "iphone", "scale": "2x", "size": "29x29"},
        {"filename": "Icon-29@3x.png", "idiom": "iphone", "scale": "3x", "size": "29x29"},
        {"filename": "Icon-40@2x.png", "idiom": "iphone", "scale": "2x", "size": "40x40"},
        {"filename": "Icon-40@3x.png", "idiom": "iphone", "scale": "3x", "size": "40x40"},
        {"filename": "Icon-60@2x.png", "idiom": "iphone", "scale": "2x", "size": "60x60"},
        {"filename": "Icon-60@3x.png", "idiom": "iphone", "scale": "3x", "size": "60x60"},
        {"filename": "Icon-1024.png", "idiom": "ios-marketing", "scale": "1x", "size": "1024x1024"},
    ],
    "info": {"author": "xcode", "version": 1},
}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, size in SIZES:
        draw_icon(size).save(OUT / name)
        print("wrote", name)
    (OUT / "Contents.json").write_text(json.dumps(CONTENTS, indent=2) + "\n")
    print("wrote Contents.json")


if __name__ == "__main__":
    main()
