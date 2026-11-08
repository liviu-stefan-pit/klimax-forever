"""The generated add-on media is deterministic and matches the committed file."""

from __future__ import annotations

from pathlib import Path

from pipeline.media.arrow import SIZE, alpha_mask, arrow_tga

ROOT = Path(__file__).resolve().parents[2]


def test_arrow_header_and_size() -> None:
    data = arrow_tga()
    assert data[2] == 2  # uncompressed true-colour
    assert data[16] == 32  # bits per pixel
    assert len(data) == 18 + SIZE * SIZE * 4


def test_arrow_is_deterministic() -> None:
    assert arrow_tga() == arrow_tga()


def test_arrow_points_up_and_is_symmetric() -> None:
    mask = alpha_mask()
    assert mask[0][SIZE // 2] == 0  # above the tip
    assert mask[SIZE // 2 + 16][SIZE // 2] == 0  # below the notch
    assert mask[SIZE - 10][12] >= 128  # inside a wing
    for row in mask:
        assert abs(row[8] - row[SIZE - 1 - 8]) <= 1


def test_committed_texture_is_current() -> None:
    committed = ROOT / "Klimax" / "Media" / "Arrow.tga"
    assert committed.read_bytes() == arrow_tga()
