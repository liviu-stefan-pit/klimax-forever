"""Rares and chests for the add-on (PRD 7.12).

Inputs (all read-only):
  data/raw/npcs.json     rank 2 (rare elite) and 4 (rare) NPCs with level <= 60
  data/raw/items.json    npcDrops, used to list notable drops for each rare
  data/raw/objects.json  objects whose name contains "Chest" (lootable chest spawns)
  data/horde/travel.json the Horde leveling zones (area ids, with a level range)
  data/ui_maps.json      areaId -> uiMapID (the add-on keys spawns by uiMapID)

Outputs: Klimax/Data/Rares.lua and Klimax/Data/Chests.lua. Spawns are map percent (0..100),
at most MAX_SPAWNS per entry, taken in zone order so the output is deterministic.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

RARE_RANKS = frozenset({2, 4})
MAX_LEVEL = 60
MAX_SPAWNS = 3
MAX_DROPS = 3
# The DB has no item quality, so "notable" means a weapon or armour piece of item level 20+,
# or a bag. Anything else is left out of the hint.
NOTABLE_ITEM_LEVEL = 20
ITEM_CLASS_CONTAINER = 1
ITEM_CLASS_WEAPON = 2
ITEM_CLASS_ARMOR = 4
CHEST_RE = re.compile(r"\bchest\b", re.IGNORECASE)
SENTINEL = (-1.0, -1.0)

DEFAULT_RAW = Path("data/raw")
DEFAULT_DATA = Path("data")
DEFAULT_ADDON = Path("Klimax/Data")

Zones = dict[int, list[tuple[float, float]]]


@dataclass
class Rare:
    id: int
    name: str
    lo: int
    hi: int
    zones: Zones
    drops: list[str] = field(default_factory=list)


@dataclass
class Chest:
    id: int
    name: str
    zones: Zones


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def area_to_ui_for_horde(travel: dict[str, Any], ui_maps: dict[str, Any]) -> dict[str, int]:
    """Area id (string) -> uiMapID, for the Horde leveling zones in travel.json only.

    A uiMapID of 0 means the display is suppressed, so there is no map to key on.
    """
    all_areas = {k: int(v) for k, v in ui_maps["areaIdToUiMapId"].items() if int(v) > 0}
    out: dict[str, int] = {}
    for zone in travel.get("zones", []):
        area = str(zone["id"])
        if area in all_areas:
            out[area] = all_areas[area]
    return out


def _spawns(entity: dict[str, Any], area_to_ui: dict[str, int]) -> Zones:
    """Spawn points keyed by uiMapID, sentinel coordinates dropped, zones in sorted order."""
    out: Zones = {}
    spawns = entity.get("spawns") or {}
    for area in sorted(spawns, key=int):
        ui = area_to_ui.get(str(area))
        if ui is None:
            continue
        for point in spawns[area]:
            x, y = float(point[0]), float(point[1])
            if (x, y) == SENTINEL:
                continue
            out.setdefault(ui, []).append((x, y))
    return out


def _cap(zones: Zones) -> Zones:
    """Keeps the first MAX_SPAWNS points across zones, in uiMapID order."""
    out: Zones = {}
    left = MAX_SPAWNS
    for ui in sorted(zones):
        if left <= 0:
            break
        pts = zones[ui][:left]
        out[ui] = pts
        left -= len(pts)
    return out


def _notable_drops(npc_id: int, items: dict[str, Any]) -> list[str]:
    ranked: list[tuple[int, str]] = []
    for item_id, item in items.items():
        if npc_id not in (item.get("npcDrops") or []):
            continue
        cls = item.get("class")
        level = int(item.get("itemLevel") or 0)
        gear = cls in (ITEM_CLASS_WEAPON, ITEM_CLASS_ARMOR) and level >= NOTABLE_ITEM_LEVEL
        if cls == ITEM_CLASS_CONTAINER or gear:
            ranked.append((-level, item.get("name") or f"item {item_id}"))
    ranked.sort()
    names: list[str] = []
    for _, name in ranked:
        if name not in names:
            names.append(name)
    return names[:MAX_DROPS]


def build_rares(
    npcs: dict[str, Any], items: dict[str, Any], area_to_ui: dict[str, int]
) -> list[Rare]:
    """Rare NPCs (rank 2 or 4, max level <= MAX_LEVEL) with at least one spawn in a Horde zone."""
    out: list[Rare] = []
    for key in sorted(npcs, key=int):
        npc = npcs[key]
        if npc.get("rank") not in RARE_RANKS or npc.get("placeholder") or not npc.get("name"):
            continue
        lo, hi = int(npc.get("minLevel") or 0), int(npc.get("maxLevel") or 0)
        if hi <= 0 or hi > MAX_LEVEL:
            continue
        zones = _cap(_spawns(npc, area_to_ui))
        if zones:
            out.append(Rare(int(key), npc["name"], lo, hi, zones, _notable_drops(int(key), items)))
    return out


def build_chests(objects: dict[str, Any], area_to_ui: dict[str, int]) -> list[Chest]:
    out: list[Chest] = []
    for key in sorted(objects, key=int):
        obj = objects[key]
        name = obj.get("name") or ""
        if not CHEST_RE.search(name) or obj.get("placeholder"):
            continue
        zones = _cap(_spawns(obj, area_to_ui))
        if zones:
            out.append(Chest(int(key), name, zones))
    return out


def _lua_str(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _lua_zones(zones: Zones, indent: str) -> list[str]:
    """One line per zone, so no generated line grows past the luacheck limit."""
    if not zones:
        return [indent + "zones = {},"]
    out = [indent + "zones = {"]
    for ui in sorted(zones):
        pts = ", ".join("{%.2f, %.2f}" % p for p in zones[ui])
        out.append(f"{indent}  [{ui}] = {{{pts}}},")
    out.append(indent + "},")
    return out


def _lua_list(name: str, items: list[str], indent: str) -> list[str]:
    if not items:
        return [f"{indent}{name} = {{}},"]
    out = [f"{indent}{name} = {{"]
    out += [f"{indent}  {_lua_str(item)}," for item in items]
    out.append(indent + "},")
    return out


def render_rares(rares: list[Rare]) -> str:
    lines = [
        "-- Generated by `python -m pipeline gen-rares`. Do not edit by hand.",
        "-- Source: data/raw/npcs.json (rank 2 and 4, max level <= 60) and data/raw/items.json",
        "-- (npcDrops). Spawns are map percent keyed by uiMapID; drops are notable items only.",
        "local _, K = ...",
        "K.Rares = {",
    ]
    for r in rares:
        lines.append("  {")
        lines.append(f"    id = {r.id}, name = {_lua_str(r.name)}, lo = {r.lo}, hi = {r.hi},")
        lines += _lua_zones(r.zones, "    ")
        lines += _lua_list("drops", r.drops, "    ")
        lines.append("  },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def render_chests(chests: list[Chest]) -> str:
    lines = [
        "-- Generated by `python -m pipeline gen-chests`. Do not edit by hand.",
        '-- Source: data/raw/objects.json (names containing "Chest") in the Horde leveling zones.',
        "-- Spawns are map percent keyed by uiMapID.",
        "local _, K = ...",
        "K.Chests = {",
    ]
    for c in chests:
        lines.append("  {")
        lines.append(f"    id = {c.id}, name = {_lua_str(c.name)},")
        lines += _lua_zones(c.zones, "    ")
        lines.append("  },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def _inputs(
    raw: Path, data: Path
) -> tuple[dict[str, int], dict[str, Any], dict[str, Any], dict[str, Any]]:
    travel = load_json(data / "horde" / "travel.json")
    ui_maps = load_json(data / "ui_maps.json")
    area_to_ui = area_to_ui_for_horde(travel, ui_maps)
    return (
        area_to_ui,
        load_json(raw / "npcs.json"),
        load_json(raw / "objects.json"),
        load_json(raw / "items.json"),
    )


def write_rares(
    raw: Path = DEFAULT_RAW, data: Path = DEFAULT_DATA, addon: Path = DEFAULT_ADDON
) -> int:
    area_to_ui, npcs, _objects, items = _inputs(raw, data)
    rares = build_rares(npcs, items, area_to_ui)
    addon.mkdir(parents=True, exist_ok=True)
    (addon / "Rares.lua").write_text(render_rares(rares), encoding="utf-8", newline="\n")
    return len(rares)


def write_chests(
    raw: Path = DEFAULT_RAW, data: Path = DEFAULT_DATA, addon: Path = DEFAULT_ADDON
) -> int:
    area_to_ui, _npcs, objects, _items = _inputs(raw, data)
    chests = build_chests(objects, area_to_ui)
    addon.mkdir(parents=True, exist_ok=True)
    (addon / "Chests.lua").write_text(render_chests(chests), encoding="utf-8", newline="\n")
    return len(chests)
