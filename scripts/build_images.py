"""Builds the site's pictures from the photography masters.

Reads every master in generated/masters/ and writes AVIF and WebP at three
widths, plus one 1600 px JPEG for sharing previews, to
priv/static/images/works/ (lots and their second views) and
priv/static/images/photos/ (the house). Then lists what it built, with each
picture's size, in priv/catalogue/images.json, which the site reads.

    python3 -I scripts/build_images.py          # build what is new or changed
    python3 -I scripts/build_images.py --all    # rebuild everything
"""

import json
import pathlib
import sys

from PIL import Image, ImageOps

ROOT = pathlib.Path(__file__).resolve().parent.parent
MASTERS = ROOT / "generated" / "masters"
OUT_WORKS = ROOT / "priv" / "static" / "images" / "works"
OUT_PHOTOS = ROOT / "priv" / "static" / "images" / "photos"
MANIFEST = ROOT / "priv" / "catalogue" / "images.json"

WIDTHS = [480, 960, 1600]
AVIF_QUALITY = 52
WEBP_QUALITY = 78
JPEG_QUALITY = 82


def shared(name):
    """Only a lot's own picture and the house photographs are used as sharing previews."""
    return not (name.endswith("-detail") or name.endswith("-room"))


def outputs(name, out, widths):
    files = [out / f"{name}-{w}.{ext}" for w in widths for ext in ("avif", "webp")]
    return files + ([out / f"{name}-{widths[-1]}.jpg"] if shared(name) else [])


BACKDROP = (0xDC, 0xD6, 0xCC)


def on_backdrop(im):
    """A studio photograph: every edge is the house backdrop, so the page can
    show it on a matching ground without a seam."""
    w, h = im.size
    small = im.resize((max(8, w // 16), max(8, h // 16)))
    sw, sh = small.size
    edge = [small.getpixel((x, 0)) for x in range(sw)] + [small.getpixel((x, sh - 1)) for x in range(sw)]
    edge += [small.getpixel((0, y)) for y in range(sh)] + [small.getpixel((sw - 1, y)) for y in range(sh)]
    close = sum(1 for p in edge if all(abs(a - b) <= 8 for a, b in zip(p, BACKDROP)))
    return close / len(edge) > 0.9


def build(master, out, rebuild):
    name = master.stem
    im = ImageOps.exif_transpose(Image.open(master)).convert("RGB")
    w, h = im.size
    studio = on_backdrop(im)
    widths = [x for x in WIDTHS if x < w] + [min(w, WIDTHS[-1])] if w < WIDTHS[-1] else WIDTHS
    widths = sorted(set(widths))
    targets = outputs(name, out, widths)

    info = {"w": w, "h": h, "widths": widths, "studio": studio}
    fresh = all(t.exists() and t.stat().st_mtime >= master.stat().st_mtime for t in targets)
    if fresh and not rebuild:
        return name, info, False

    out.mkdir(parents=True, exist_ok=True)
    for width in widths:
        size = (width, round(h * width / w))
        small = im if size == im.size else im.resize(size, Image.LANCZOS)
        small.save(out / f"{name}-{width}.avif", quality=AVIF_QUALITY, speed=4)
        small.save(out / f"{name}-{width}.webp", quality=WEBP_QUALITY, method=6)
        if width == widths[-1] and shared(name):
            small.save(out / f"{name}-{width}.jpg", quality=JPEG_QUALITY, optimize=True, progressive=True)

    return name, info, True


def main():
    rebuild = "--all" in sys.argv
    manifest = {}
    built = 0

    for master in sorted(MASTERS.glob("*.jpg")):
        out = OUT_PHOTOS if master.stem.startswith("photo-") else OUT_WORKS
        name, info, did = build(master, out, rebuild)
        manifest[name] = info
        built += did

    # A lot's second view travels with its work.
    for name in list(manifest):
        for kind in ("detail", "room"):
            second = f"{name}-{kind}"
            if second in manifest:
                manifest[name]["second"] = {"file": second, "kind": kind, **{k: manifest[second][k] for k in ("w", "h")}}

    MANIFEST.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    total = sum(p.stat().st_size for d in (OUT_WORKS, OUT_PHOTOS) if d.exists() for p in d.iterdir())
    print(f"{len(manifest)} pictures, {built} built now, {total / 1e6:.1f} MB on disk -> {MANIFEST.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
