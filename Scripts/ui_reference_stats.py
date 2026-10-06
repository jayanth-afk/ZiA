#!/usr/bin/env python3
"""Pixel statistics for rendered UI reference images.

A capture can be checked mechanically — non-blank, expected dimensions, and
light/dark variants that actually differ — instead of relying on a human to
open every file.

Usage:
    # 1. render references
    .build/debug/Jarvis --render-ui build/ui-references
    # 2. report
    python3 Scripts/ui_reference_stats.py build/ui-references
"""

import os
import struct
import subprocess
import sys
import tempfile

BMP_HEADER = struct.Struct("<2sIHHI")
DIB_HEADER = struct.Struct("<IiiHHIIiiII")


def read_bmp(path):
    with open(path, "rb") as handle:
        data = handle.read()

    signature, _, _, _, pixel_offset = BMP_HEADER.unpack_from(data, 0)
    if signature != b"BM":
        raise ValueError("not a BMP file")

    (
        dib_size,
        width,
        height,
        _planes,
        bpp,
        compression,
        _image_size,
        _xppm,
        _yppm,
        _colors_used,
        _colors_important,
    ) = DIB_HEADER.unpack_from(data, 14)

    if dib_size < 40 or bpp not in (24, 32):
        raise ValueError(f"unsupported BMP (bpp={bpp})")

    # compression 0 = RGB, 3 = BITFIELDS (what sips emits for 32bpp).
    if compression == 0:
        if bpp == 24:
            red_mask, green_mask, blue_mask = 0xFF0000, 0x00FF00, 0x0000FF
        else:
            red_mask, green_mask, blue_mask = 0x00FF0000, 0x0000FF00, 0x000000FF
    elif compression == 3:
        # BITFIELDS: masks live in the DIB header (BITMAPINFOHEADER puts them
        # inline at offset 40, and BITMAPV4/V5 headers carry them as fields at
        # the same offsets).
        red_mask, green_mask, blue_mask = struct.unpack_from("<III", data, 14 + 40)
    else:
        raise ValueError(f"unsupported BMP compression {compression}")

    def channel_offset(mask):
        for shift in range(0, 32, 8):
            if mask == (0xFF << shift):
                return shift // 8
        raise ValueError(f"unsupported channel mask {mask:#x}")

    offsets = (channel_offset(red_mask), channel_offset(green_mask), channel_offset(blue_mask))

    bottom_up = height > 0
    height = abs(height)
    bytes_per_pixel = bpp // 8
    row_stride = ((width * bpp + 31) // 32) * 4

    return data, pixel_offset, width, height, bytes_per_pixel, row_stride, bottom_up, offsets


def stats(path, sample_step=4):
    data, offset, width, height, bpp, stride, bottom_up, offsets = read_bmp(path)
    red_shift, green_shift, blue_shift = offsets

    total = 0.0
    total_squares = 0.0
    count = 0
    distinct = set()

    for y in range(0, height, sample_step):
        row = y if bottom_up else height - 1 - y
        base = offset + row * stride
        for x in range(0, width, sample_step):
            index = base + x * bpp
            red = data[index + red_shift]
            green = data[index + green_shift]
            blue = data[index + blue_shift]
            luminance = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
            total += luminance
            total_squares += luminance * luminance
            count += 1
            distinct.add((red >> 3) << 10 | (green >> 3) << 5 | (blue >> 3))

    mean = total / count if count else 0.0
    variance = max(0.0, total_squares / count - mean * mean) if count else 0.0
    return width, height, mean, variance ** 0.5, len(distinct)


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else "build/ui-references"
    names = sorted(f for f in os.listdir(directory) if f.endswith(".png"))
    if not names:
        print(f"no PNG files in {directory}")
        return 1

    print(f"{'file':<42} {'size':>11} {'meanL':>7} {'stdL':>7} {'colors':>7}  verdict")
    blank = 0
    with tempfile.TemporaryDirectory() as work:
        for name in names:
            source = os.path.join(directory, name)
            converted = os.path.join(work, name[:-4] + ".bmp")
            subprocess.run(
                ["sips", "-s", "format", "bmp", source, "--out", converted],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            width, height, mean, std, colors = stats(converted)
            is_blank = colors <= 2
            blank += is_blank
            verdict = "BLANK" if is_blank else ("flat" if std < 0.005 else "ok")
            print(f"{name:<42} {width:>5}x{height:<5} {mean:>7.3f} {std:>7.3f} {colors:>7}  {verdict}")

    print()
    print(f"{len(names)} image(s); {blank} blank")
    return 2 if blank else 0


if __name__ == "__main__":
    sys.exit(main())
