#!/usr/bin/env python3
"""Lay out the PNGs in a directory as a grid, each scaled to 390 px wide with its file name below.

Usage: contact_sheet.py <in_dir> <out_png>
"""

import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

TILE_WIDTH = 390
MAX_COLUMNS = 4
GUTTER = 16
LABEL_HEIGHT = 24
BACKGROUND = (255, 255, 255)
TEXT = (0, 0, 0)


class ContactSheetError(Exception):
    pass


def list_pngs(in_dir):
    names = sorted(n for n in os.listdir(in_dir) if n.lower().endswith(".png"))
    if not names:
        raise ContactSheetError(f"no PNG files in {in_dir}")
    return names


def _font():
    try:
        return ImageFont.load_default(size=14)
    except TypeError:  # Pillow < 10.1 has no sized default font
        return ImageFont.load_default()


def build_sheet(in_dir, out_png):
    """Write the contact sheet and return (columns, rows)."""
    tiles = []
    for name in list_pngs(in_dir):
        with Image.open(os.path.join(in_dir, name)) as source:
            image = source.convert("RGB")
        height = round(image.height * TILE_WIDTH / image.width)
        tiles.append((name, image.resize((TILE_WIDTH, height), Image.Resampling.LANCZOS)))

    columns = min(MAX_COLUMNS, len(tiles))
    rows = math.ceil(len(tiles) / columns)
    row_heights = []
    for row in range(rows):
        row_tiles = tiles[row * columns:(row + 1) * columns]
        row_heights.append(max(image.height for _, image in row_tiles) + LABEL_HEIGHT)

    width = columns * TILE_WIDTH + (columns - 1) * GUTTER + 2 * GUTTER
    height = sum(row_heights) + (rows - 1) * GUTTER + 2 * GUTTER
    sheet = Image.new("RGB", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(sheet)
    font = _font()

    y = GUTTER
    for row in range(rows):
        x = GUTTER
        for name, image in tiles[row * columns:(row + 1) * columns]:
            sheet.paste(image, (x, y))
            draw.text((x, y + image.height + 4), name, fill=TEXT, font=font)
            x += TILE_WIDTH + GUTTER
        y += row_heights[row] + GUTTER

    sheet.save(out_png, optimize=True)
    return columns, rows


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        columns, rows = build_sheet(argv[1], argv[2])
    except ContactSheetError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"wrote {argv[2]} ({columns} columns, {rows} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
