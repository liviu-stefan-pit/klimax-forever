"""Generates ``Klimax/Media/Arrow.tga``: a clean white arrowhead pointing up.

The texture is white with an alpha mask, so the add-on tints it with a vertex colour and turns
it with ``Texture:SetRotation``. Output is byte-for-byte deterministic.
Run: ``python -m pipeline.media.arrow`` (writes the file) or call :func:`arrow_tga`.
"""

from __future__ import annotations

import struct
from pathlib import Path

SIZE = 64
SAMPLES = 4  # supersampling per axis for the anti-aliased edge
# Arrowhead polygon in pixel space, clockwise from the tip: tip, right wing, notch, left wing.
POLYGON = ((32.0, 5.0), (55.0, 57.0), (32.0, 43.0), (9.0, 57.0))
DEFAULT_OUT = Path("Klimax/Media/Arrow.tga")


def _inside(x: float, y: float) -> bool:
    """Even-odd point-in-polygon test."""
    hit = False
    n = len(POLYGON)
    for i in range(n):
        x1, y1 = POLYGON[i]
        x2, y2 = POLYGON[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            hit = not hit
    return hit


def alpha_mask() -> list[list[int]]:
    """SIZE x SIZE alpha values (0-255), row 0 at the top."""
    rows = []
    for py in range(SIZE):
        row = []
        for px in range(SIZE):
            covered = 0
            for sy in range(SAMPLES):
                for sx in range(SAMPLES):
                    x = px + (sx + 0.5) / SAMPLES
                    y = py + (sy + 0.5) / SAMPLES
                    covered += _inside(x, y)
            row.append(round(255 * covered / (SAMPLES * SAMPLES)))
        rows.append(row)
    return rows


def arrow_tga() -> bytes:
    """An uncompressed 32-bit TGA, top-left origin, BGRA pixels (white with the alpha mask)."""
    header = struct.pack(
        "<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28
    )
    pixels = bytearray()
    for row in alpha_mask():
        for a in row:
            pixels += bytes((255, 255, 255, a))
    return header + bytes(pixels)


def main() -> None:
    DEFAULT_OUT.parent.mkdir(parents=True, exist_ok=True)
    DEFAULT_OUT.write_bytes(arrow_tga())
    print(f"wrote {DEFAULT_OUT} ({DEFAULT_OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
