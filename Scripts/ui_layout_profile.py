#!/usr/bin/env python3
"""Layout profile for rendered UI reference images.

Answers where content actually sits inside a capture and whether it is clipped,
which pixel *statistics* alone cannot show. It says nothing about beauty — it is
a mechanical check that the composition landed where it was composed.

For each image it prints:
  * the content bounding box (pixels differing from the capture background), and
    whether that box touches an edge (i.e. the composition is clipped)
  * a vertical band profile (mean luminance + share of content pixels per band),
    so the structure of a surface can be read top to bottom

Usage:
    python3 Scripts/ui_layout_profile.py build/ui-references/02-hud-idle.png
"""

import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ui_reference_stats import read_bmp  # noqa: E402

DIFFERENCE = 0.045  # luminance distance that counts as "content"


def load(path, work):
    converted = os.path.join(work, os.path.basename(path)[:-4] + ".bmp")
    subprocess.run(
        ["sips", "-s", "format", "bmp", path, "--out", converted],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return read_bmp(converted)


def luminance(data, index, offsets):
    red = data[index + offsets[0]]
    green = data[index + offsets[1]]
    blue = data[index + offsets[2]]
    return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0


def profile(path, work, bands=16):
    data, offset, width, height, bpp, stride, bottom_up, offsets = load(path, work)

    def row_base(y):
        row = y if bottom_up else height - 1 - y
        return offset + row * stride

    # Background estimate: median luminance of the outer 3-pixel frame, which is
    # the capture's own backdrop (the surface sits inside it).
    border = []
    for y in range(height):
        base = row_base(y)
        if y < 3 or y >= height - 3:
            for x in range(width):
                border.append(luminance(data, base + x * bpp, offsets))
        else:
            for x in list(range(0, 3)) + list(range(width - 3, width)):
                border.append(luminance(data, base + x * bpp, offsets))
    border.sort()
    background = border[len(border) // 2]

    rows = []
    min_x, max_x, min_y, max_y = width, -1, height, -1
    for y in range(height):
        base = row_base(y)
        total = 0.0
        content = 0
        for x in range(width):
            value = luminance(data, base + x * bpp, offsets)
            total += value
            if abs(value - background) > DIFFERENCE:
                content += 1
                min_x = min(min_x, x)
                max_x = max(max_x, x)
                min_y = min(min_y, y)
                max_y = max(max_y, y)
        rows.append((total / width, content / width))

    name = os.path.basename(path)
    print(f"== {name}  {width}x{height}  backgroundL={background:.3f}")

    if max_x < 0:
        print("   (no content above the background threshold)")
        return

    def touches(value, limit):
        return "EDGE" if value <= 0 or value >= limit - 1 else ""

    edges = " ".join(
        filter(
            None,
            [
                "left:" + touches(min_x, width) if min_x <= 0 else "",
                "right:" + touches(max_x, width) if max_x >= width - 1 else "",
                "top:" + touches(min_y, height) if min_y <= 0 else "",
                "bottom:" + touches(max_y, height) if max_y >= height - 1 else "",
            ],
        )
    )
    print(f"   content bbox x[{min_x}..{max_x}] y[{min_y}..{max_y}]"
          + (f"  CLIPPED AT {edges}" if edges else "  (not clipped)"))

    step = max(1, height // bands)
    for start in range(0, height, step):
        chunk = rows[start:min(start + step, height)]
        mean = sum(r[0] for r in chunk) / len(chunk)
        share = sum(r[1] for r in chunk) / len(chunk)
        bar = "#" * int(round(share * 60))
        print(f"   y {start:>4}..{min(start + step, height) - 1:<4} "
              f"meanL={mean:.3f} content={share * 100:5.1f}% {bar}")


def main():
    paths = sys.argv[1:]
    if not paths:
        directory = "build/ui-references"
        paths = [os.path.join(directory, f) for f in sorted(os.listdir(directory))
                 if f.endswith(".png") and f.startswith("0")]
    with tempfile.TemporaryDirectory() as work:
        for path in paths:
            profile(path, work)
            print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
