#!/usr/bin/env python3
"""Generate the Orvia app, in-app and monochrome menu bar assets."""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / 'Orvia/Resources/Assets.xcassets'
MASTER = ROOT / 'Orvia/Resources/Brand/orvia-master.png'
ICON = ASSETS / 'AppIcon.appiconset'
MARK = ASSETS / 'OrviaMark.imageset'
MENU = ASSETS / 'OrviaMenuBarIcon.imageset'
SIZES = {
    'icon_16x16.png': 16, 'icon_16x16@2x.png': 32,
    'icon_32x32.png': 32, 'icon_32x32@2x.png': 64,
    'icon_128x128.png': 128, 'icon_128x128@2x.png': 256,
    'icon_256x256.png': 256, 'icon_256x256@2x.png': 512,
    'icon_512x512.png': 512, 'icon_512x512@2x.png': 1024,
}


def main() -> None:
    master = Image.open(MASTER).convert('RGBA')
    for filename, size in SIZES.items():
        master.resize((size, size), Image.Resampling.LANCZOS).save(ICON / filename, optimize=True)
    master.resize((512, 512), Image.Resampling.LANCZOS).save(MARK / 'orvia-mark.png', optimize=True)

    pixels = master.load()
    mask = Image.new('L', master.size)
    output = mask.load()
    for y in range(master.height):
        for x in range(master.width):
            if (x - master.width / 2) ** 2 + (y - master.height / 2) ** 2 > (master.width * .36) ** 2:
                continue
            r, g, _, alpha = pixels[x, y]
            brightness = max(r - 95, g - 110)
            output[x, y] = min(255, max(0, brightness * 3)) * alpha // 255
    bounds = mask.getbbox()
    if bounds is None:
        raise ValueError('Could not extract the Orvia mark')
    mask = mask.crop(bounds)
    for size, filename in [(18, 'orvia-menubar.png'), (36, 'orvia-menubar@2x.png')]:
        glyph = mask.resize((round(size * .83), round(size * .83)), Image.Resampling.LANCZOS)
        canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        symbol = Image.new('RGBA', glyph.size, (0, 0, 0, 255))
        symbol.putalpha(glyph)
        canvas.alpha_composite(symbol, ((size - glyph.width) // 2, (size - glyph.height) // 2))
        canvas.save(MENU / filename, optimize=True)


if __name__ == '__main__':
    main()
