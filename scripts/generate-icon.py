#!/usr/bin/env python3
"""从原创 SVG 生成已随源码提交的 macOS iconset；正常构建无需这些 Python 依赖。"""

from io import BytesIO
from pathlib import Path

import cairosvg
from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Resources/HearNote.iconset"
ICON_SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def main():
    rendered = cairosvg.svg2png(
        url=str(ROOT / "Resources/HearNote.svg"),
        output_width=2048,
        output_height=2048,
    )
    with Image.open(BytesIO(rendered)) as source:
        master = source.convert("RGBA")
    ICONSET.mkdir(parents=True, exist_ok=True)
    for name, size in ICON_SIZES.items():
        # 预乘 alpha 后缩放，防止透明边缘产生深色晕边。
        icon = master.convert("RGBa").resize(
            (size, size), Image.Resampling.LANCZOS
        ).convert("RGBA")
        icon.save(ICONSET / name, optimize=True)
        print(f"{name}: {size} × {size}")


if __name__ == "__main__":
    main()
