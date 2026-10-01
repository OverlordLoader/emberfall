#!/usr/bin/env python3
"""Export approved artwork/app-icon.png into the iOS AppIcon catalog.

Requires Pillow. The approved master stays opaque; iOS masks its corners.
"""
import json
from pathlib import Path
import shutil
from PIL import Image

HERE = Path(__file__).resolve().parent.parent
SOURCE = HERE / "artwork/app-icon.png"
OUT = HERE / "Emberfall/Assets.xcassets/AppIcon.appiconset"
SIZES = [
    ("Icon-20@2x.png", 40, "20x20", "2x", "iphone"),
    ("Icon-20@3x.png", 60, "20x20", "3x", "iphone"),
    ("Icon-29@2x.png", 58, "29x29", "2x", "iphone"),
    ("Icon-29@3x.png", 87, "29x29", "3x", "iphone"),
    ("Icon-40@2x.png", 80, "40x40", "2x", "iphone"),
    ("Icon-40@3x.png", 120, "40x40", "3x", "iphone"),
    ("Icon-60@2x.png", 120, "60x60", "2x", "iphone"),
    ("Icon-60@3x.png", 180, "60x60", "3x", "iphone"),
    ("Icon-1024.png", 1024, "1024x1024", "1x", "ios-marketing"),
]


def main():
    with Image.open(SOURCE) as source:
        if source.size != (1024, 1024) or source.mode != "RGB":
            raise ValueError("Approved master must be a 1024x1024 RGB PNG without alpha.")
        master = source.copy()
    OUT.mkdir(parents=True, exist_ok=True)
    images = []
    for filename, px, size, scale, idiom in SIZES:
        if px == 1024:
            shutil.copyfile(SOURCE, OUT / filename)
        else:
            master.resize((px, px), Image.Resampling.LANCZOS).save(OUT / filename)
        images.append({"filename": filename, "idiom": idiom, "scale": scale, "size": size})
    (OUT / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Exported {len(images)} icons from {SOURCE.relative_to(HERE)}")


if __name__ == "__main__":
    main()
