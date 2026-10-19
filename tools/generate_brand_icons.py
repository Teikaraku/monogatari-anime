"""Render the Monogatari wordmark and its platform resources.

Requires Pillow and fontTools. Pass --font to use a local Noto Sans SC font.
The checked-in SVG contains outlines, so the shipped app needs no extra font.
"""
import argparse
from io import BytesIO
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024
INK = '#ff2d55'
GLYPH_SIZE = 620


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--font', type=Path,
                        default=Path('C:/Windows/Fonts/NotoSansSC-VF.ttf'))
    args = parser.parse_args()
    font = TTFont(args.font)
    if 'fvar' in font:
        font = instantiateVariableFont(font, {'wght': 900}, inplace=False)
    glyph_set = font.getGlyphSet()
    glyph = glyph_set[font.getBestCmap()[ord('番')]]
    bounds_pen = BoundsPen(glyph_set)
    glyph.draw(bounds_pen)
    x0, y0, x1, y1 = bounds_pen.bounds
    scale = GLYPH_SIZE / max(x1 - x0, y1 - y0)
    tx = SIZE / 2 - scale * (x0 + x1) / 2
    ty = SIZE / 2 + scale * (y0 + y1) / 2
    path_pen = SVGPathPen(glyph_set)
    glyph.draw(path_pen)
    branding = ROOT / 'assets/branding'
    branding.mkdir(parents=True, exist_ok=True)
    (branding / 'monogatari.svg').write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">\n'
        '  <title>物语 / Monogatari — 番</title>\n'
        '  <rect width="1024" height="1024" fill="#fff"/>\n'
        f'  <path fill="{INK}" transform="matrix({scale:.8f} 0 0 {-scale:.8f} '
        f'{tx:.8f} {ty:.8f})" d="{path_pen.getCommands()}"/>\n</svg>\n',
        encoding='utf-8',
    )
    font_data = BytesIO()
    font.save(font_data)
    font_bytes = font_data.getvalue()
    oversample = 4
    face = ImageFont.truetype(BytesIO(font_bytes), SIZE * oversample)
    box = face.getbbox('番')
    font_size = round(SIZE * oversample * GLYPH_SIZE * oversample /
                      max(box[2] - box[0], box[3] - box[1]))
    face = ImageFont.truetype(BytesIO(font_bytes), font_size)
    box = face.getbbox('番')
    mask = Image.new('L', (SIZE * oversample,) * 2)
    ImageDraw.Draw(mask).text(
        ((SIZE * oversample - box[2] + box[0]) / 2 - box[0],
         (SIZE * oversample - box[3] + box[1]) / 2 - box[1]),
        '番', font=face, fill=255,
    )
    mask = mask.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    foreground = Image.new('RGBA', (SIZE, SIZE), INK)
    foreground.putalpha(mask)
    square = Image.new('RGB', (SIZE, SIZE), 'white')
    square.paste(foreground, mask=mask)
    rounded = square.convert('RGBA')
    corners = Image.new('L', (SIZE, SIZE))
    ImageDraw.Draw(corners).rounded_rectangle(
        (0, 0, SIZE - 1, SIZE - 1), radius=224, fill=255)
    rounded.putalpha(corners)
    monochrome = Image.new('RGBA', (SIZE, SIZE), 'black')
    monochrome.putalpha(mask)

    def save(image, relative, size=None):
        destination = ROOT / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if size is not None:
            image = image.resize(size, Image.Resampling.LANCZOS)
        image.save(destination)

    for name in ('logo_android.png', 'logo_ios.png'):
        save(square, f'assets/images/logo/{name}')
    save(rounded, 'assets/images/logo/logo_rounded.png')
    save(rounded, 'assets/images/logo/logo_linux.png', (512, 512))
    save(foreground, 'assets/images/logo/logo_foreground.png')
    save(monochrome, 'assets/images/logo/logo_monochrome.png')
    dark = Image.new('RGB', (SIZE, SIZE), '#212121')
    dark.paste(foreground, mask=mask)
    save(dark, 'assets/images/logo/logo_splash_dark.png')
    notification = Image.new('RGBA', (SIZE, SIZE), 'white')
    notification.putalpha(mask)
    save(notification, 'android/app/src/main/res/drawable/ic_stat_monogatari.png',
         (96, 96))
    for name in ('logo_windows.ico', 'logo_lanczos.ico'):
        save(rounded, f'assets/images/logo/{name}')
    save(square, 'fastlane/metadata/android/en-US/images/icon.png', (512, 512))

    # The existing iOS launch storyboard uses these six image references.
    launch = ROOT / 'ios/Runner/Assets.xcassets/LaunchImage.imageset'
    for file in launch.glob('*.png'):
        with Image.open(file) as previous:
            dimensions = previous.size
        background = Image.new('RGB', (SIZE, SIZE),
                               '#212121' if 'Dark' in file.name else 'white')
        background.paste(foreground, mask=mask)
        save(background, file.relative_to(ROOT), dimensions)

    # Web and Linux also share the brand even though the main targets are native.
    save(square, 'web/favicon.png', (32, 32))
    for size in (192, 512):
        for name in (f'Icon-{size}.png', f'Icon-maskable-{size}.png'):
            save(square, f'web/icons/{name}', (size, size))
    print('Created outlined SVG, shared logos, tray icons, and splash resources.')


if __name__ == '__main__':
    main()
