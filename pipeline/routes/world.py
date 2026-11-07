"""Read-only view of the game data that the validator and compiler check routes against.

``World.load`` reads ``data/raw`` and ``data/<faction>``. Tests build a ``World`` directly from
small dictionaries, so the route tooling can be tested without the (git-ignored) raw data.
"""

from __future__ import annotations

import json
import math
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from pipeline.shape.factions import FactionConfig, get_faction
from pipeline.shape.xp_table import XP_TO_NEXT, xp_for_levels

# Race token used in route JSON -> name used by FactionConfig.race_bits.
RACE_TOKENS: dict[str, str] = {
    "Human": "Human",
    "Dwarf": "Dwarf",
    "NightElf": "Night Elf",
    "Gnome": "Gnome",
    "Orc": "Orc",
    "Undead": "Undead",
    "Tauren": "Tauren",
    "Troll": "Troll",
}


def norm_name(name: str) -> str:
    """Lower-case alphanumerics only: 'The Barrens' and 'THE_BARRENS' compare equal."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def to_int_keys(mapping: dict[Any, Any]) -> dict[int, Any]:
    return {int(key): value for key, value in mapping.items()}


def distance(x1: float, y1: float, x2: float, y2: float) -> float:
    """Euclidean distance in map-percent."""
    return math.hypot(x1 - x2, y1 - y2)


@dataclass
class World:
    faction: FactionConfig
    quests: dict[int, dict[str, Any]]
    npcs: dict[int, dict[str, Any]]
    objects: dict[int, dict[str, Any]]
    # quest id -> [quest level, xp]
    xp: dict[int, list[int]]
    travel: dict[str, Any]
    # raw/zones.json 'zoneIDs' (ENUM -> area id) and 'areaIdToUiMapId' overrides
    zone_enum: dict[str, int] = field(default_factory=dict)
    area_to_ui_map: dict[int, int] = field(default_factory=dict)
    manifest: dict[str, Any] = field(default_factory=dict)
    # pack id -> pack JSON; the callable is used when the id is not cached
    packs: dict[str, dict[str, Any]] = field(default_factory=dict)
    pack_loader: Callable[[str], dict[str, Any] | None] | None = None

    def __post_init__(self) -> None:
        self._zone_by_name: dict[str, int] = {}
        self._zone_names: dict[int, str] = {}
        for zone in self.travel.get("zones", []):
            self._zone_by_name[norm_name(zone["name"])] = zone["id"]
            self._zone_by_name[norm_name(zone.get("enum", zone["name"]))] = zone["id"]
            self._zone_names[zone["id"]] = zone["name"]
        for enum_name, area_id in self.zone_enum.items():
            self._zone_by_name.setdefault(norm_name(enum_name), area_id)
            self._zone_names.setdefault(area_id, enum_name.replace("_", " ").title())

    # ---- loading -------------------------------------------------------------------------

    @classmethod
    def load(
        cls, faction_id: str = "horde", raw: Path = Path("data/raw"), data: Path = Path("data")
    ) -> World:
        def read(path: Path) -> Any:
            return json.loads(path.read_text(encoding="utf-8"))

        zones = read(raw / "zones.json")
        bands = data / faction_id / "bands"

        def load_pack(pack_id: str) -> dict[str, Any] | None:
            path = bands / f"{pack_id}.json"
            return read(path) if path.exists() else None

        return cls(
            faction=get_faction(faction_id),
            quests=to_int_keys(read(raw / "quests.json")),
            npcs=to_int_keys(read(raw / "npcs.json")),
            objects=to_int_keys(read(raw / "objects.json")),
            xp=to_int_keys(read(raw / "xp.json")),
            travel=read(data / faction_id / "travel.json"),
            zone_enum=zones.get("zoneIDs", {}),
            area_to_ui_map=to_int_keys(zones.get("areaIdToUiMapId", {})),
            manifest=read(raw / "manifest.json"),
            pack_loader=load_pack,
        )

    # ---- zones ---------------------------------------------------------------------------

    def zone_id(self, name: str) -> int | None:
        return self._zone_by_name.get(norm_name(name))

    def zone_name(self, zone_id: int) -> str:
        return self._zone_names.get(zone_id, f"zone {zone_id}")

    # ---- quests --------------------------------------------------------------------------

    def quest_name(self, quest_id: int) -> str:
        return str(self.quests.get(quest_id, {}).get("name", f"quest {quest_id}"))

    def quest_xp(self, quest_id: int) -> int | None:
        row = self.xp.get(quest_id)
        return row[1] if row else None

    def race_bits(self, token: str) -> int:
        return self.faction.race_bits.get(RACE_TOKENS.get(token, token), 0)

    def faction_available(self, quest: dict[str, Any]) -> bool:
        """Horde availability: no race restriction, a Horde race bit, or the Horde flag."""
        mask = int(quest.get("requiredRaces", 0))
        if mask == 0:
            return True
        return bool(mask & (self.faction.race_mask | self.faction.faction_flag))

    def quest_races_mask(self, quest: dict[str, Any]) -> int:
        """Race bits only (the Forever faction flags removed)."""
        return int(quest.get("requiredRaces", 0)) & self.faction.race_mask

    # ---- spawns --------------------------------------------------------------------------

    def entity_spawns(self, kind: str, entity_id: int) -> list[tuple[int, float, float]]:
        """All usable (zone id, x, y) spawns of an NPC ('n') or object ('o'). Skips [-1, -1]."""
        table = self.npcs if kind == "n" else self.objects
        record = table.get(entity_id)
        if not record:
            return []
        out: list[tuple[int, float, float]] = []
        for zone, points in (record.get("spawns") or {}).items():
            for point in points:
                if point[0] is None or point[0] < 0 or point[1] < 0:
                    continue
                out.append((int(zone), float(point[0]), float(point[1])))
        return out

    def quest_giver(self, quest_id: int, role: str) -> list[tuple[str, int]]:
        """Starters ('startedBy') or finishers ('finishedBy') as [('n'|'o'|'i', id)]."""
        block = self.quests.get(quest_id, {}).get("startedBy" if role == "start" else "finishedBy")
        out: list[tuple[str, int]] = []
        for key, kind in (("npcs", "n"), ("objects", "o"), ("items", "i")):
            out.extend((kind, int(i)) for i in (block or {}).get(key, []) or [])
        return out

    # ---- packs ---------------------------------------------------------------------------

    def pack(self, pack_id: str) -> dict[str, Any] | None:
        if pack_id not in self.packs and self.pack_loader is not None:
            loaded = self.pack_loader(pack_id)
            if loaded is not None:
                self.packs[pack_id] = loaded
        return self.packs.get(pack_id)

    # ---- XP / levels ---------------------------------------------------------------------

    def db_stamp(self) -> dict[str, str]:
        info = self.manifest.get("questiedb", {})
        return {
            "questieDbVersion": str(info.get("version", "")),
            "buildCommit": str(info.get("build_commit", "")),
        }


def xp_budget(lo: int, hi: int) -> int:
    return xp_for_levels(lo, hi)


def level_at_xp(lo: int, xp: float) -> float:
    """Fractional player level after earning ``xp`` points starting at the start of level lo."""
    level = lo
    remaining = xp
    while level < 60 and remaining >= XP_TO_NEXT[level]:
        remaining -= XP_TO_NEXT[level]
        level += 1
    if level >= 60:
        return 60.0
    return level + remaining / XP_TO_NEXT[level]
