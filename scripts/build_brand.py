"""Builds Umber's mark, favicons, app icons and sharing picture.

The mark is the capital U of Bodoni Moda (weight 500, optical size 96), in
brass on the salesroom's umber-black. The outline is taken from the font
itself, so the SVG favicon does not depend on the font being loaded.

    python3 -I scripts/build_brand.py
"""

import io
import pathlib
import tempfile

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONTS = ROOT / "priv" / "static" / "fonts"
OUT = ROOT / "priv" / "static" / "images" / "brand"
SHARE = ROOT / "priv" / "static" / "images" / "share"
MASTERS = ROOT / "generated" / "masters"

NIGHT = "#120d0a"
BRASS = "#c9a46a"
PAPER = "#f2ede4"


def instance(src, **axes):
    font = TTFont(src)
    font.flavor = None
    inst = instancer.instantiateVariableFont(font, axes)
    tmp = tempfile.NamedTemporaryFile(suffix=".ttf", delete=False)
    inst.save(tmp.name)
    return inst, tmp.name


def svg_mark(inst, size=64, glyph_height=0.62):
    gs = inst.getGlyphSet()
    name = inst.getBestCmap()[ord("U")]
    bp = BoundsPen(gs)
    gs[name].draw(bp)
    x0, y0, x1, y1 = bp.bounds
    scale = size * glyph_height / (y1 - y0)
    w = (x1 - x0) * scale
    h = (y1 - y0) * scale
    dx = (size - w) / 2 - x0 * scale
    dy = (size + h) / 2 + y0 * scale
    pen = SVGPathPen(gs)
    # Font units go up; SVG goes down.
    gs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, dx, dy)))
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}">'
        f'<rect width="{size}" height="{size}" rx="{size * 0.18:.2f}" fill="{NIGHT}"/>'
        f'<path d="{pen.getCommands()}" fill="{BRASS}"/></svg>\n'
    )


def raster(ttf, size, glyph_height=0.62, background=NIGHT, color=BRASS, radius=0.18, transparent=False):
    scale = 4
    s = size * scale
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if not transparent:
        d.rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * radius), fill=background)
    font = ImageFont.truetype(ttf, int(s * glyph_height * 1.33))
    l, t, r, b = d.textbbox((0, 0), "U", font=font)
    # Scale the glyph so its cap height is exactly glyph_height of the square.
    k = (s * glyph_height) / (b - t)
    font = ImageFont.truetype(ttf, int(s * glyph_height * 1.33 * k))
    l, t, r, b = d.textbbox((0, 0), "U", font=font)
    d.text(((s - (r - l)) / 2 - l, (s - (b - t)) / 2 - t), "U", font=font, fill=color)
    return im.resize((size, size), Image.LANCZOS)


def share_image(display_ttf, text_ttf):
    w, h = 1200, 630
    photo = MASTERS / "photo-salesroom.jpg"
    if photo.exists():
        base = ImageOps.fit(Image.open(photo).convert("RGB"), (w, h), centering=(0.55, 0.5))
    else:
        base = Image.new("RGB", (w, h), NIGHT)
    # Darken the left for the words.
    shade = Image.new("L", (w, h))
    shade_draw = ImageDraw.Draw(shade)
    solid, clear = 0.5 * w, 0.82 * w
    for x in range(w):
        a = 238 if x < solid else int(238 * max(0.0, (clear - x) / (clear - solid)))
        shade_draw.line([(x, 0), (x, h)], fill=a)
    base = Image.composite(Image.new("RGB", (w, h), NIGHT), base, shade)
    d = ImageDraw.Draw(base)
    big = ImageFont.truetype(display_ttf, 132)
    small = ImageFont.truetype(text_ttf, 26)
    d.text((72, 300), "Umber", font=big, fill=PAPER, anchor="ls")
    d.text((76, 352), "AUCTIONEERS · NAIROBI", font=small, fill=BRASS, anchor="ls")
    line = ImageFont.truetype(text_ttf, 30)
    d.text((76, 440), "Modern and contemporary East African art", font=line, fill=PAPER, anchor="ls")
    d.text((76, 482), "and collectable design, live and online.", font=line, fill=PAPER, anchor="ls")
    return base


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    SHARE.mkdir(parents=True, exist_ok=True)
    # Display cut for the large wordmark; a small optical size, with sturdier
    # hairlines, for the icons, which are seen at 16 to 192 pixels.
    _, display = instance(FONTS / "bodoni-moda-latin-normal.woff2", wght=500, opsz=96)
    icon_inst, icon = instance(FONTS / "bodoni-moda-latin-normal.woff2", wght=640, opsz=11)
    _, text = instance(FONTS / "schibsted-grotesk-latin-normal.woff2", wght=600)

    (OUT / "favicon.svg").write_text(svg_mark(icon_inst))
    raster(icon, 180, radius=0).convert("RGB").save(OUT / "apple-touch-icon.png", optimize=True)
    raster(icon, 192).save(OUT / "icon-192.png", optimize=True)
    raster(icon, 512).save(OUT / "icon-512.png", optimize=True)
    raster(icon, 512, glyph_height=0.46, radius=0).convert("RGB").save(OUT / "icon-maskable-512.png", optimize=True)
    raster(icon, 512).save(OUT / "umber-mark-512.png", optimize=True)
    raster(icon, 96, glyph_height=0.7, color="#ffffff", transparent=True).save(OUT / "badge-96.png", optimize=True)

    ico = [raster(icon, s) for s in (16, 32, 48)]
    ico[2].save(ROOT / "priv" / "static" / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)], append_images=ico[:2])

    share_image(display, text).save(SHARE / "umber-share.jpg", quality=86, optimize=True, progressive=True)
    print("brand files written to", OUT.relative_to(ROOT), "and", SHARE.relative_to(ROOT))


if __name__ == "__main__":
    main()
