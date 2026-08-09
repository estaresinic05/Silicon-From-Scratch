#!/usr/bin/env python3
"""
Trim the dead space off Innovus screenshots.

    python3 scripts/crop_shots.py docs/images

`fit` in Innovus fits the die to the layout WINDOW, and the window is rarely
the same shape as the capture, so a 2400x2400 dump typically comes back with
the die filling under half the frame and the rest pure black. Placed six
inches wide in a report that wastes most of the width.

This finds the bounding box of everything that is not background and crops to
it with a small margin, in place. Idempotent: an already-tight image is left
alone. Originals are kept alongside as <name>.orig.png the first time a file
is cropped, so this can never be the step that loses a screenshot.
"""

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageChops
except ImportError:
    sys.exit("Pillow is required:  pip install Pillow")


def content_box(img, threshold):
    """Bounding box of everything brighter than `threshold` on black."""
    grey = img.convert("L")
    # point() to a mask first: getbbox() alone treats any non-zero pixel as
    # content, and JPEG-ish ringing or a stray dark grey axis would defeat it.
    mask = grey.point(lambda p: 255 if p > threshold else 0)
    return mask.getbbox()


def crop_one(path, margin, threshold, min_gain):
    img = Image.open(path)
    if img.mode not in ("RGB", "RGBA", "L"):
        img = img.convert("RGB")

    box = content_box(img, threshold)
    if box is None:
        return None, "image is entirely background"

    l, t, r, b = box
    w, h = img.size
    l = max(0, l - margin)
    t = max(0, t - margin)
    r = min(w, r + margin)
    b = min(h, b + margin)

    area_before = w * h
    area_after = (r - l) * (b - t)
    gain = 1 - area_after / area_before
    if gain < min_gain:
        return None, f"already tight ({gain:.0%} would be trimmed)"

    orig = path.with_suffix(".orig.png")
    if not orig.exists():
        img.save(orig)

    img.crop((l, t, r, b)).save(path)
    return (w, h, r - l, b - t, gain), None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("directory", help="folder of .png screenshots")
    ap.add_argument("--margin", type=int, default=24,
                    help="pixels of breathing room to keep (default 24)")
    ap.add_argument("--threshold", type=int, default=12,
                    help="brightness above which a pixel counts as content (0-255)")
    ap.add_argument("--min-gain", type=float, default=0.04,
                    help="skip files where less than this fraction would be trimmed")
    args = ap.parse_args()

    d = Path(args.directory)
    pngs = sorted(p for p in d.glob("*.png") if not p.name.endswith(".orig.png"))
    if not pngs:
        sys.exit(f"no .png files in {d}")

    for p in pngs:
        result, why = crop_one(p, args.margin, args.threshold, args.min_gain)
        if result is None:
            print(f"{p.name:26} skipped, {why}")
        else:
            w, h, nw, nh, gain = result
            print(f"{p.name:26} {w}x{h} -> {nw}x{nh}   {gain:.0%} of the frame was empty")


if __name__ == "__main__":
    main()
