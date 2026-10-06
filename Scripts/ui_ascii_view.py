#!/usr/bin/env python3
"""Coarse ASCII view of a rendered UI reference image.

A terminal-sized impression of where light and structure sit in a capture. This
is a real look at the composition (element positions, relative weight, empty
space) at low resolution — it is not a substitute for viewing the image, and it
cannot judge taste.

Usage:
    python3 Scripts/ui_ascii_view.py build/ui-references/02-hud-idle.png --cols 110
"""

import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ui_reference_stats import read_bmp  # noqa: E402

RAMP = " .:-=+*#%@"


def ascii_view(path, cols=110, work=None):
    with tempfile.TemporaryDirectory() as tmp:
        work = work or tmp
        converted = os.path.join(work, os.path.basename(path)[:-4] + ".bmp")
        subprocess.run(
            ["sips", "-s", "format", "bmp", path, "--out", converted],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        data, offset, width, height, bpp, stride, bottom_up, off = read_bmp(converted)

        rows = max(1, int(cols * 0.45 * height / width))
        step_x = width / cols
        step_y = height / rows

        values = []
        for row in range(rows):
            line = []
            y0 = int(row * step_y)
            y1 = max(y0 + 1, min(height, int((row + 1) * step_y)))
            for col in range(cols):
                x0 = int(col * step_x)
                x1 = max(x0 + 1, min(width, int((col + 1) * step_x)))
                total = 0.0
                count = 0
                for y in range(y0, y1, max(1, (y1 - y0) // 3)):
                    # BMP stores bottom-up rows when the DIB height is positive.
                    src_row = (height - 1 - y) if bottom_up else y
                    base = offset + src_row * stride
                    for x in range(x0, x1, max(1, (x1 - x0) // 3)):
                        i = base + x * bpp
                        total += (0.2126 * data[i + off[0]] + 0.7152 * data[i + off[1]]
                                  + 0.0722 * data[i + off[2]]) / 255.0
                        count += 1
                line.append(total / count if count else 0.0)
            values.append(line)

        flat = [v for line in values for v in line]
        low = min(flat)
        high = max(flat)
        span = max(1e-6, high - low)

        print(f"== {os.path.basename(path)}  {width}x{height}  "
              f"lum {low:.3f}..{high:.3f}  ({cols}x{rows} cells)")
        for line in values:
            print("   " + "".join(
                RAMP[min(len(RAMP) - 1, max(0, int((v - low) / span * (len(RAMP) - 1) + 0.5)))]
                for v in line
            ))


def main():
    args = []
    cols = 110
    argv = sys.argv[1:]
    index = 0
    while index < len(argv):
        if argv[index] == "--cols" and index + 1 < len(argv):
            cols = int(argv[index + 1])
            index += 2
        else:
            args.append(argv[index])
            index += 1
    for path in args:
        ascii_view(path, cols=cols)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
