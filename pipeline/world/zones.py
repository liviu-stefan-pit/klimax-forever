"""Zone model: which zones are compiled, their ids, file names and XP-weighted level ranges."""

from __future__ import annotations

import re
from dataclasses import dataclass

from pipeline.routes.ui_maps import ui_map_for
from pipeline.shape.data import RawData, pretty_zone
from pipeline.shape.xp_table import XP_TO_NEXT

# Weighted percentiles of quest level that bound a zone's real range (phase 09 note: min and max
# are useless, "The Barrens 14-59"). The weight of a quest is the share of a level its XP is worth
# at its own level (see level_weight), so the range is where the zone's leveling progress lies and
# a lone high-level quest with a large XP reward barely moves it.
LOW_PCT = 0.10
HIGH_PCT = 0.90
WEIGHT_SCALE = 10000


@dataclass(frozen=True)
class Zone:
    enum: str
    area: int
    ui_map: int
    name: str

    @property
    def key(self) -> str:
        """Stable lower-case key used in hub ids (``durotar``, ``zephras_isle``)."""
        return self.enum.lower()

    @property
    def file_stem(self) -> str:
        """``Durotar``, ``TirisfalGlades``, ``ZephrasIsle``."""
        return "".join(
            w.capitalize() for w in re.findall(r"[A-Za-z0-9]+", self.name.replace("'", ""))
        )


class ZoneError(ValueError):
    """A configured zone is unknown or has no uiMapID."""


def resolve_zones(raw: RawData, enums: tuple[str, ...]) -> list[Zone]:
    """Zones sorted by uiMapID."""
    out: list[Zone] = []
    for enum in enums:
        if enum not in raw.zone_by_name:
            raise ZoneError(f"zone '{enum}' is not in zones.json zoneIDs")
        area = raw.zone_by_name[enum]
        ui_map = ui_map_for(area)
        if not ui_map:
            raise ZoneError(f"zone '{enum}' (area {area}) has no uiMapID")
        out.append(Zone(enum, area, ui_map, pretty_zone(enum)))
    return sorted(out, key=lambda z: z.ui_map)


def weighted_percentile(pairs: list[tuple[int, int]], pct: float) -> int:
    """``pairs`` = (value, weight). Smallest value whose cumulative weight reaches ``pct``."""
    items = sorted((v, w) for v, w in pairs if w > 0)
    if not items:
        return 0
    total = sum(w for _, w in items)
    running = 0
    for value, weight in items:
        running += weight
        if running >= pct * total:
            return value
    return items[-1][0]


def level_range(pairs: list[tuple[int, int]]) -> list[int] | None:
    """``[low, median, high]`` of quest levels weighted by XP, or None without XP data."""
    if not any(w > 0 for _, w in pairs):
        return None
    return [
        weighted_percentile(pairs, LOW_PCT),
        weighted_percentile(pairs, 0.5),
        weighted_percentile(pairs, HIGH_PCT),
    ]


def level_weight(level: int, xp: int | None, xp_by_level: dict[int, int]) -> int:
    """XP of a quest as a share of the level it is done at (x WEIGHT_SCALE). Quests without an XP
    row (Forever's own) use the median XP of their level."""
    level = min(max(level, 1), 59)
    value = xp if xp else xp_by_level.get(level, 0)
    return round(value * WEIGHT_SCALE / XP_TO_NEXT[level])
