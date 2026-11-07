"""Travel graph (``data/<faction>/travel.json``).

Generated from the DB: zones and level ranges, flight master candidates, zeppelin platforms,
innkeepers, class trainers and food/water/ammo vendors. Hand-typed facts (zone adjacency,
zeppelin and boat routes, settlement names) sit under ``manual`` with a note.
"""

from __future__ import annotations

import re
from typing import Any

from pipeline.shape.context import ShapeContext
from pipeline.shape.coords import valid_spawns
from pipeline.shape.factions import TRAINER_SUBNAMES
from pipeline.shape.places import MANUAL_NOTE, SETTLEMENTS, settlement_name

ITEM_CONSUMABLE = 0
ITEM_SUBCLASS_FOOD = 5
ITEM_PROJECTILE = 6
PROJECTILE_ARROW, PROJECTILE_BULLET = 2, 3
# Heuristic: DB gives no drink flag (foodType is 0 for everything), so drinks that restore
# mana are recognised by name. Alcohol is deliberately not matched.
_WATER_RE = re.compile(r"\b(water|milk|juice|dew|nectar|tea)\b", re.IGNORECASE)

# Hand-typed adjacency (zone enum names). `via` is a description, not a coordinate.
ADJACENCY: tuple[tuple[str, str, str], ...] = (
    ("DUROTAR", "ORGRIMMAR", "Orgrimmar gates"),
    ("DUROTAR", "THE_BARRENS", "road from Razor Hill / Orgrimmar north to the Crossroads"),
    ("DUROTAR", "AZSHARA", "east of Orgrimmar"),
    ("MULGORE", "THUNDER_BLUFF", "Thunder Bluff elevator"),
    ("MULGORE", "THE_BARRENS", "Red Rocks to Camp Taurajo road"),
    ("THE_BARRENS", "STONETALON_MOUNTAINS", "north-west of the Crossroads"),
    ("THE_BARRENS", "ASHENVALE", "north of the Crossroads"),
    ("THE_BARRENS", "THOUSAND_NEEDLES", "south, past Camp Taurajo"),
    ("THE_BARRENS", "DUSTWALLOW_MARSH", "south-east, towards Theramore"),
    ("STONETALON_MOUNTAINS", "ASHENVALE", "north"),
    ("STONETALON_MOUNTAINS", "DESOLACE", "south"),
    ("ASHENVALE", "AZSHARA", "east"),
    ("ASHENVALE", "FELWOOD", "north"),
    ("FELWOOD", "WINTERSPRING", "north-east"),
    ("FELWOOD", "MOONGLADE", "Moonglade tunnel"),
    ("WINTERSPRING", "MOONGLADE", "Moonglade path"),
    ("DESOLACE", "FERALAS", "south"),
    ("THOUSAND_NEEDLES", "FERALAS", "west"),
    ("THOUSAND_NEEDLES", "TANARIS", "south"),
    ("TANARIS", "UN_GORO_CRATER", "west"),
    ("TANARIS", "SILITHUS", "south-west"),
    ("UN_GORO_CRATER", "SILITHUS", "south"),
    ("TIRISFAL_GLADES", "UNDERCITY", "Undercity entrance"),
    ("TIRISFAL_GLADES", "SILVERPINE_FOREST", "south-west road past the Sepulcher"),
    ("TIRISFAL_GLADES", "WESTERN_PLAGUELANDS", "east"),
    ("SILVERPINE_FOREST", "HILLSBRAD_FOOTHILLS", "south-east"),
    ("HILLSBRAD_FOOTHILLS", "ARATHI_HIGHLANDS", "south"),
    ("HILLSBRAD_FOOTHILLS", "ALTERAC_MOUNTAINS", "north-east"),
    ("ARATHI_HIGHLANDS", "THE_HINTERLANDS", "east"),
    ("WESTERN_PLAGUELANDS", "EASTERN_PLAGUELANDS", "east"),
    ("SEARING_GORGE", "BURNING_STEPPES", "north-east"),
    ("SEARING_GORGE", "BADLANDS", "south"),
    ("BADLANDS", "SWAMP_OF_SORROWS", "far south"),
    ("SWAMP_OF_SORROWS", "BLASTED_LANDS", "south"),
)

ZEPPELIN_SITES = {
    "DUROTAR": "Orgrimmar Zeppelin Tower",
    "TIRISFAL_GLADES": "Undercity Zeppelin Tower",
    "STRANGLETHORN_VALE": "Grom'gol Base Camp",
}
ZEPPELIN_ROUTES = (
    ("Orgrimmar Zeppelin Tower", "Undercity Zeppelin Tower"),
    ("Orgrimmar Zeppelin Tower", "Grom'gol Base Camp"),
    ("Undercity Zeppelin Tower", "Grom'gol Base Camp"),
)
BOAT_ROUTES = (("Ratchet", "Booty Bay"),)


def _percentile(sorted_values: list[int], pct: float) -> int:
    """Nearest-rank percentile of a pre-sorted list."""
    idx = max(0, min(len(sorted_values) - 1, round(pct * (len(sorted_values) - 1))))
    return sorted_values[idx]


def _first_point(npc: dict[str, Any]) -> tuple[int, float, float] | None:
    pts = valid_spawns(npc.get("spawns"))
    return pts[0] if pts else None


def _place(ctx: ShapeContext, zone: int, x: float, y: float) -> str:
    name = settlement_name(ctx.cfg.id, ctx.raw.zone_by_name, zone, x, y)
    return name or ctx.zone_name(zone)


def _zone_sort(ctx: ShapeContext, zone: int) -> tuple[int, int]:
    order = {n: i for i, n in enumerate(ctx.cfg.zone_order)}
    name = ctx.raw.zone_by_id.get(zone, "")
    return (order.get(name, len(order)), zone)


def _npc_entry(ctx: ShapeContext, nid: int) -> dict[str, Any] | None:
    npc = ctx.raw.npcs[nid]
    pt = _first_point(npc)
    if pt is None:
        return None
    zone, x, y = pt
    return {
        "id": nid,
        "name": npc.get("name", ""),
        "zone": zone,
        "zoneName": ctx.zone_name(zone),
        "x": round(x, 1),
        "y": round(y, 1),
        "place": _place(ctx, zone, x, y),
    }


def _friendly(ctx: ShapeContext, npc: dict[str, Any]) -> bool:
    return ctx.cfg.own_code in (npc.get("friendlyToFaction") or "")


def _sorted_entries(ctx: ShapeContext, entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(entries, key=lambda e: (_zone_sort(ctx, e["zone"]), e["x"], e["y"], e["id"]))


def _zones_section(ctx: ShapeContext) -> list[dict[str, Any]]:
    """Zones of the faction's world: the configured zone order, branch zones and any zone with
    a friendly service NPC (which picks up Forever-only zones such as Zephra's Isle)."""
    cfg, raw = ctx.cfg, ctx.raw
    wanted = {raw.zone_by_name[n] for n in cfg.zone_order if n in raw.zone_by_name}
    for branch in cfg.branches:
        wanted |= {raw.zone_by_name[n] for n in (*branch.home_zones, *branch.reach_zones)}
    wanted |= {z for _t, z, *_rest in ctx.service_npcs()}
    levels: dict[int, list[int]] = {}
    for info in ctx.quests.values():
        if info.zone in wanted:
            levels.setdefault(info.zone, []).append(info.level)
    out = []
    for zone in sorted(wanted, key=lambda z: _zone_sort(ctx, z)):
        vals = sorted(levels.get(zone, []))
        entry: dict[str, Any] = {
            "id": zone,
            "name": ctx.zone_name(zone),
            "enum": raw.zone_by_id.get(zone),
            "quests": len(vals),
        }
        if vals:
            entry["levelRange"] = [_percentile(vals, 0.1), _percentile(vals, 0.9)]
            entry["levelMinMax"] = [vals[0], vals[-1]]
        out.append(entry)
    return out


def _flight_masters(ctx: ShapeContext) -> list[dict[str, Any]]:
    names = set(ctx.cfg.flight_master_subnames)
    out = []
    for nid, npc in ctx.raw.npcs.items():
        if npc.get("subName") not in names or not _friendly(ctx, npc):
            continue
        entry = _npc_entry(ctx, nid)
        if entry is None:
            continue
        entry["subName"] = npc["subName"]
        same = entry["place"] == entry["zoneName"]
        entry["nodeName"] = entry["place"] if same else f"{entry['place']}, {entry['zoneName']}"
        entry["nodeNameSource"] = "derived from place + zone (not in the DB)"
        out.append(entry)
    return _sorted_entries(ctx, out)


def _zeppelin_platforms(ctx: ShapeContext) -> list[dict[str, Any]]:
    out = []
    for nid, npc in ctx.raw.npcs.items():
        if npc.get("subName") != "Zeppelin Master" or not _friendly(ctx, npc):
            continue
        entry = _npc_entry(ctx, nid)
        if entry is None:
            continue
        zone_enum = ctx.raw.zone_by_id.get(entry["zone"], "")
        entry["site"] = ZEPPELIN_SITES.get(zone_enum, entry["place"])
        out.append(entry)
    return _sorted_entries(ctx, out)


def _innkeepers(ctx: ShapeContext) -> list[dict[str, Any]]:
    out = []
    for nid, npc in ctx.raw.npcs.items():
        if npc.get("subName") == "Innkeeper" and _friendly(ctx, npc):
            entry = _npc_entry(ctx, nid)
            if entry:
                out.append(entry)
    return _sorted_entries(ctx, out)


def _class_trainers(ctx: ShapeContext) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = {t: [] for t in sorted(set(TRAINER_SUBNAMES.values()))}
    for nid, npc in ctx.raw.npcs.items():
        token = TRAINER_SUBNAMES.get(npc.get("subName") or "")
        if token and _friendly(ctx, npc):
            entry = _npc_entry(ctx, nid)
            if entry:
                out[token].append(entry)
    return {k: _sorted_entries(ctx, v) for k, v in out.items()}


def _vendors(ctx: ShapeContext) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    """Vendors that sell food, water or ammo, from the inverse ``Item.vendors`` map."""
    sold: dict[int, dict[str, set[int]]] = {}
    for iid, item in ctx.raw.items.items():
        if not item.get("vendors"):
            continue
        cls, sub = item.get("class"), item.get("subClass")
        kind = None
        if cls == ITEM_CONSUMABLE and sub == ITEM_SUBCLASS_FOOD:
            kind = "water" if _WATER_RE.search(item.get("name", "")) else "food"
        elif cls == ITEM_PROJECTILE and sub == PROJECTILE_ARROW:
            kind = "arrow"
        elif cls == ITEM_PROJECTILE and sub == PROJECTILE_BULLET:
            kind = "bullet"
        if not kind:
            continue
        for nid in item["vendors"]:
            if nid in ctx.raw.npcs and _friendly(ctx, ctx.raw.npcs[nid]):
                sold.setdefault(nid, {}).setdefault(kind, set()).add(iid)
    entries = []
    names: dict[str, dict[str, Any]] = {}
    for nid, kinds in sold.items():
        entry = _npc_entry(ctx, nid)
        if entry is None:
            continue
        for kind in ("food", "water", "arrow", "bullet"):
            ids = sorted(kinds.get(kind, ()), key=lambda i: (ctx.raw.items[i]["requiredLevel"], i))
            if ids:
                entry[kind] = ids
                for i in ids:
                    names[str(i)] = {
                        "n": ctx.raw.items[i]["name"],
                        "rl": ctx.raw.items[i]["requiredLevel"],
                    }
        entries.append(entry)
    return _sorted_entries(ctx, entries), dict(sorted(names.items(), key=lambda kv: int(kv[0])))


def build_travel(ctx: ShapeContext) -> dict[str, Any]:
    raw, cfg = ctx.raw, ctx.cfg
    vendors, item_names = _vendors(ctx)
    manual_adj = [
        {"a": a, "b": b, "via": via}
        for a, b, via in ADJACENCY
        if a in raw.zone_by_name and b in raw.zone_by_name
    ]
    settlements = [
        {"zone": z, "x": x, "y": y, "name": n} for z, x, y, n in SETTLEMENTS.get(cfg.id, ())
    ]
    q = raw.manifest.get("questiedb", {})
    return {
        "_note": (
            "Generated by `python -m pipeline shape` from data/raw. Everything under `manual` is "
            "hand-typed; all other sections come from the DB. flightMasters are candidates "
            "(subName + friendly to the faction); nodeName is derived, the DB has no taxi node "
            "names."
        ),
        "db": {"buildCommit": q.get("build_commit"), "questieDbVersion": q.get("version")},
        "faction": cfg.id,
        "zones": _zones_section(ctx),
        "flightMasters": _flight_masters(ctx),
        "zeppelins": {"platforms": _zeppelin_platforms(ctx)},
        "innkeepers": _innkeepers(ctx),
        "classTrainers": _class_trainers(ctx),
        "vendors": vendors,
        "itemNames": item_names,
        "manual": {
            "note": (
                "Typed by hand in phase 02 from game knowledge, not from the DB. Adjacency has no "
                "border coordinates; `anchors` in the Klimax route data should use the settlement "
                "positions below. Verify in game before relying on it (phase 06+)."
            ),
            "adjacency": manual_adj,
            "zeppelinRoutes": [{"from": a, "to": b} for a, b in ZEPPELIN_ROUTES],
            "boatRoutes": [
                {
                    "from": a,
                    "to": b,
                    "note": "Dock positions are not in the DB; fill in when verified in game.",
                }
                for a, b in BOAT_ROUTES
            ],
            "settlements": settlements,
            "settlementsNote": MANUAL_NOTE,
            "vendorHeuristic": "water = item name matches water|milk|juice|dew|nectar|tea; "
            "other class-0/subclass-5 items are food; "
            "ammo from class 6 subclass 2 (arrow) / 3 (bullet)",
        },
    }
