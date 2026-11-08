"""Load ``data/raw/*.json`` into int-keyed indexes for the shape step."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_RAW = Path("data/raw")

# Zone enum names whose title-casing needs help.
_ZONE_NAME_OVERRIDES = {
    "UN_GORO_CRATER": "Un'Goro Crater",
    "ZUL_FARRAK": "Zul'Farrak",
    "ZUL_GURUB": "Zul'Gurub",
    "ZEPHRAS_ISLE": "Zephra's Isle",
}
_SMALL_WORDS = {"OF", "THE", "AND", "IN"}


def pretty_zone(enum_name: str) -> str:
    if enum_name in _ZONE_NAME_OVERRIDES:
        return _ZONE_NAME_OVERRIDES[enum_name]
    words = enum_name.split("_")
    out = []
    for i, word in enumerate(words):
        out.append(word.lower() if (i and word in _SMALL_WORDS) else word.capitalize())
    return " ".join(out)


def _int_keys(table: dict[str, Any]) -> dict[int, Any]:
    return {int(k): v for k, v in table.items()}


@dataclass
class RawData:
    quests: dict[int, dict[str, Any]]
    npcs: dict[int, dict[str, Any]]
    objects: dict[int, dict[str, Any]]
    items: dict[int, dict[str, Any]]
    xp: dict[int, tuple[int, int]]
    zones: dict[str, Any]
    manifest: dict[str, Any]
    objective_hints: dict[str, list[int]]
    zone_by_name: dict[str, int] = field(default_factory=dict)
    zone_by_id: dict[int, str] = field(default_factory=dict)
    dungeon_ids: set[int] = field(default_factory=set)
    dungeon_names: dict[int, str] = field(default_factory=dict)

    @property
    def raid_ids(self) -> set[int]:
        return {zid for zid, name in self.dungeon_names.items() if name in RAID_NAMES}

    def zone_name(self, zone_id: int) -> str:
        if zone_id in self.zone_by_id:
            return pretty_zone(self.zone_by_id[zone_id])
        if zone_id in self.dungeon_names:
            return self.dungeon_names[zone_id]
        return f"Zone {zone_id}"

    def zone_id(self, enum_name: str) -> int:
        try:
            return self.zone_by_name[enum_name]
        except KeyError:
            raise KeyError(f"zone '{enum_name}' is not in zones.json zoneIDs") from None


# Raid instances (any expansion in the Forever zone table). Raids add nothing to leveling to 60,
# so shape drops quests that belong to them. 5-man dungeons are kept as optional content.
RAID_NAMES = frozenset(
    {
        "Molten Core", "Blackwing Lair", "Onyxia's Lair", "Zul'Gurub",
        "Ruins of Ahn'Qiraj", "Temple of Ahn'Qiraj", "Naxxramas", "Gruul's Lair",
        "Magtheridon's Lair", "Karazhan", "Hyjal Summit", "Black Temple", "Tempest Keep",
        "Sunwell Plateau", "Zul'Aman", "Ulduar", "The Eye of Eternity", "The Obsidian Sanctum",
        "Vault of Archavon", "Icecrown Citadel", "Trial of the Crusader", "The Ruby Sanctum",
        "Baradin Hold", "Blackwing Descent", "The Bastion of Twilight",
        "Throne of the Four Winds", "Firelands", "Dragon Soul", "Mogu'shan Vaults",
        "Heart of Fear", "Terrace of Endless Spring", "Throne of Thunder",
        "Siege of Orgrimmar",
    }
)  # fmt: skip


# Quest sort ids (``zoneOrSort``) that QuestieDB uses for a dungeon whose ``dungeons.lua`` row has
# another area id: Zul'Farrak quests are sorted under 978 (the row is 1176) and Sunken Temple
# quests under 1417 (the row is 1477, The Temple of Atal'Hakkar). No NPC or object spawns in
# either alias, so they only make those quests count as dungeon quests (phase 31).
DUNGEON_SORT_ALIASES: dict[int, int] = {978: 1176, 1417: 1477}


def _dungeon_info(dungeons: dict[str, Any]) -> tuple[set[int], dict[int, str]]:
    """``dungeons.lua`` rows are either ``{"1": name, ...}`` or ``[name, ...]``."""
    ids: set[int] = set()
    names: dict[int, str] = {}
    for key, row in dungeons.items():
        zid = int(key)
        ids.add(zid)
        if isinstance(row, dict):
            name = row.get("1")
        elif isinstance(row, list) and row:
            name = row[0]
        else:
            name = None
        if isinstance(name, str):
            names[zid] = name
    for alias, zid in DUNGEON_SORT_ALIASES.items():
        if zid in ids:
            ids.add(alias)
            if zid in names:
                names.setdefault(alias, names[zid])
    return ids, names


def load_raw(raw_dir: Path = DEFAULT_RAW) -> RawData:
    def read(name: str) -> Any:
        with (raw_dir / name).open(encoding="utf-8") as fh:
            return json.load(fh)

    zones = read("zones.json")
    by_name = {name: int(zid) for name, zid in zones["zoneIDs"].items()}
    by_id: dict[int, str] = {}
    for name in sorted(by_name):  # sorted: first (alphabetical) name wins on collisions
        by_id.setdefault(by_name[name], name)
    dungeon_ids, dungeon_names = _dungeon_info(zones.get("dungeons", {}))
    hints_path = raw_dir / "objective_hints.json"
    hints = read("objective_hints.json") if hints_path.exists() else {}
    return RawData(
        quests=_int_keys(read("quests.json")),
        npcs=_int_keys(read("npcs.json")),
        objects=_int_keys(read("objects.json")),
        items=_int_keys(read("items.json")),
        xp={int(k): (int(v[0]), int(v[1])) for k, v in read("xp.json").items()},
        zones=zones,
        manifest=read("manifest.json"),
        objective_hints=hints,
        zone_by_name=by_name,
        zone_by_id=by_id,
        dungeon_ids=dungeon_ids,
        dungeon_names=dungeon_names,
    )


_WORD = re.compile(r"[a-z0-9']+")


def words(text: str) -> set[str]:
    return set(_WORD.findall(text.lower()))
