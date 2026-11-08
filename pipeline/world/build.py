"""Build the world model (plain dicts, deterministic) from the raw extract, travel.json and the
curated corrections. ``pipeline.world.lua`` turns it into Lua; the validator checks it."""

from __future__ import annotations

import json
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from pipeline.routes.ui_maps import ui_map_for
from pipeline.shape.context import ShapeContext
from pipeline.shape.coords import valid_spawns
from pipeline.shape.data import RawData, load_raw
from pipeline.shape.factions import get_faction
from pipeline.shape.places import settlement_name
from pipeline.world import npcs as npcmod
from pipeline.world.config import MAX_NPC_POINTS, WorldConfig
from pipeline.world.corrections import Corrections
from pipeline.world.hubs import HubMember, cluster_hubs
from pipeline.world.quests import QuestGraph, is_event
from pipeline.world.services import ALL_ROLES, HUB_SERVICE_ROLES, ServiceIndex
from pipeline.world.spine import compile_spine
from pipeline.world.travel import build_travel, neighbours
from pipeline.world.zones import Zone, level_range, level_weight, resolve_zones

OUTSIDE = 0  # pseudo-zone for entities homed in a zone that is not compiled


@dataclass
class WorldModel:
    config: WorldConfig
    db: dict[str, str]
    zones: list[Zone]
    # uiMap -> zone table (OUTSIDE holds only npcs/objects)
    tables: dict[int, dict[str, Any]]
    index: dict[str, Any]
    travel: dict[str, Any]
    graph: QuestGraph
    corrections: Corrections
    # quest ids compiled, per uiMap
    compiled: dict[int, list[int]] = field(default_factory=dict)
    service_index: ServiceIndex | None = None
    # counters for the report (quests left out and why)
    stats: dict[str, int] = field(default_factory=dict)


def corrections_path(data: Path, faction: str) -> Path:
    return data / faction / "world" / "corrections.json"


def load_inputs(
    raw_dir: Path, data: Path, faction: str
) -> tuple[RawData, dict[str, Any], Corrections]:
    raw = load_raw(raw_dir)
    travel = json.loads((data / faction / "travel.json").read_text(encoding="utf-8"))
    return raw, travel, Corrections.load(corrections_path(data, faction))


def _point(area: int, x: float, y: float) -> list[Any] | None:
    ui_map = ui_map_for(area)
    if not ui_map:
        return None
    return [ui_map, round(float(x), 2), round(float(y), 2)]


def build_world(
    raw: RawData,
    travel_json: dict[str, Any],
    corrections: Corrections,
    config: WorldConfig | None = None,
) -> WorldModel:
    config = config or WorldConfig()
    cfg = get_faction(config.faction)
    ctx = ShapeContext(raw, cfg)
    ctx.build_quests()
    graph = QuestGraph(ctx)
    zones = resolve_zones(raw, config.zones)
    by_area = {z.area: z for z in zones}
    status = corrections.quest_status()
    tips = corrections.quest_tips()
    equivalents = corrections.equivalent_groups()
    eq_of = {qid: group[0] for group in equivalents for qid in group}
    overrides: dict[int, list[Any]] = {}
    for row in corrections.npc_positions:
        area = raw.zone_by_name.get(row["zone"])
        pos = _point(area, row["x"], row["y"]) if area is not None else None
        if pos is not None:
            overrides[int(row["npc"])] = pos

    # ---- quests ------------------------------------------------------------------------------
    compiled: dict[int, list[int]] = {z.ui_map: [] for z in zones}
    stats: dict[str, int] = {"aboveLevel": 0, "events": 0}
    for qid in sorted(ctx.quests):
        info = ctx.quests[qid]
        if info.zone not in by_area:
            continue
        if max(int(info.raw.get("requiredLevel", 0)), 1) > config.max_required_level:
            stats["aboveLevel"] += 1
            continue
        if is_event(info.raw):
            stats["events"] += 1
            continue
        compiled[by_area[info.zone].ui_map].append(qid)
    xp_by_level = graph.xp_by_level()
    tables: dict[int, dict[str, Any]] = {
        z.ui_map: {"quests": {}, "npcs": {}, "objects": {}, "items": {}} for z in zones
    }
    tables[OUTSIDE] = {"npcs": {}, "objects": {}}
    quest_zone: dict[int, int] = {}
    interactive: set[tuple[str, int]] = set()
    referenced_by: dict[tuple[str, int], int] = {}
    for ui_map, qids in compiled.items():
        for qid in qids:
            record = graph.record(qid, _point)
            if qid in eq_of:
                record["eq"] = eq_of[qid]
            if qid in status:
                record["cx"] = status[qid]
            if qid in tips:
                record["tip"] = tips[qid]
            tables[ui_map]["quests"][qid] = record
            quest_zone[qid] = ui_map
            info = ctx.quests[qid]
            for kind, ident in (*info.starters, *info.finishers):
                if kind in ("n", "o"):
                    interactive.add((kind, ident))
            refs = graph.referenced_entities(qid)
            for nid in refs["npcs"]:
                referenced_by.setdefault(("n", nid), ui_map)
            for oid in refs["objects"]:
                referenced_by.setdefault(("o", oid), ui_map)
            for iid in sorted(refs["items"]):
                if iid in raw.items:
                    tables[ui_map]["items"][iid] = npcmod.item_record(raw, iid)

    # ---- NPCs and objects --------------------------------------------------------------------
    services = ServiceIndex(raw, cfg)
    entity_zone: dict[tuple[str, int], int] = {}
    instances: set[int] = set()

    def home(ref: tuple[str, int]) -> int:
        kind, ident = ref
        table = raw.npcs if kind == "n" else raw.objects
        area = npcmod.home_area(valid_spawns(table.get(ident, {}).get("spawns")))
        if area is None:
            return referenced_by.get(ref, OUTSIDE)
        zone = by_area.get(area)
        return zone.ui_map if zone else OUTSIDE

    wanted: set[tuple[str, int]] = {
        r for r in referenced_by if r[1] in (raw.npcs if r[0] == "n" else raw.objects)
    }
    for nid in services.roles:
        ref = ("n", nid)
        if home(ref) != OUTSIDE:
            wanted.add(ref)
    for oid in services.mailboxes:
        ref = ("o", oid)
        if home(ref) != OUTSIDE:
            wanted.add(ref)
    for ref in sorted(wanted):
        ui_map = home(ref)
        entity_zone[ref] = ui_map
        kind, ident = ref
        if kind == "n":
            roles = services.roles.get(ident)
            record = tables[ui_map]["npcs"][ident] = npcmod.npc_record(
                raw,
                ident,
                roles=roles,
                with_points=ref in interactive or bool(roles),
                point=_point,
                limit=MAX_NPC_POINTS,
                override=overrides.get(ident),
            )
            if "p" not in record and graph.instanced(ref):
                record["inst"] = min(int(z) for z in raw.npcs[ident]["spawns"])
                instances.add(record["inst"])
        else:
            roles = ["mail"] if ident in set(services.mailboxes) else None
            record = tables[ui_map]["objects"][ident] = npcmod.object_record(
                raw, ident, roles=roles, point=_point, limit=MAX_NPC_POINTS
            )
            if "p" not in record and graph.instanced(ref):
                record["inst"] = min(int(z) for z in raw.objects[ident]["spawns"])
                instances.add(record["inst"])

    # ---- travel, hubs, services ----------------------------------------------------------------
    travel = build_travel(travel_json, raw, config.travel_costs)
    near = _fallback_zones(travel, {z.ui_map for z in zones})
    area_of_ui = {ui_map_for(a): a for a in raw.zone_by_id if ui_map_for(a)}
    for zone in zones:
        table = tables[zone.ui_map]
        table["hubs"] = _hubs(zone, compiled, ctx, raw, cfg.id, config)
        for hub in table["hubs"]:
            _hub_services(hub, zone, services, near, area_of_ui, config)
        table["services"] = {
            role: sorted(ident for _kind, ident in services.providers(zone.area, role))
            for role in ALL_ROLES
            if services.providers(zone.area, role)
        }
        pairs = [
            (int(q["lv"]), level_weight(int(q["lv"]), q.get("xp"), xp_by_level))
            for q in table["quests"].values()
        ]
        table["meta"] = {
            "area": zone.area,
            "id": zone.ui_map,
            "key": zone.key,
            "name": zone.name,
        }
        lv = level_range(pairs)
        if lv:
            table["meta"]["lv"] = lv

    index = _index(zones, tables, quest_zone, entity_zone, graph, equivalents)
    index["xpl"] = [xp_by_level[level] for level in range(1, 61)]
    index["dungeons"] = dungeon_entrances(raw, instances)
    spine = compile_spine(corrections.spine, raw)
    if spine is not None:
        index["spine"] = spine
    stamp = raw.manifest.get("questiedb", {})
    db = {
        "questieDbVersion": str(stamp.get("version", "")),
        "buildCommit": str(stamp.get("build_commit", "")),
    }
    return WorldModel(
        config=config,
        db=db,
        zones=zones,
        tables=tables,
        index=index,
        travel=travel,
        graph=graph,
        corrections=corrections,
        compiled=compiled,
        service_index=services,
        stats=stats,
    )


def _fallback_zones(travel: dict[str, Any], compiled: set[int]) -> dict[int, list[int]]:
    """uiMap -> zones to look in when a hub's own zone has no provider of a role: walkable
    neighbours before boat/zeppelin destinations, compiled zones (the capitals) first, then by
    uiMapID. So Durotar falls back to Orgrimmar, not to The Barrens or Stranglethorn."""
    walk = neighbours(travel)
    out: dict[int, list[int]] = {}
    for ui_map in sorted(set(walk) | {link["m"] for link in travel["links"]}):
        ranked: dict[int, tuple[int, int, int]] = {}
        for other in walk.get(ui_map, []):
            ranked[other] = (0, 0 if other in compiled else 1, other)
        for link in travel["links"]:
            if link["m"] == ui_map and link["to"] != ui_map and link["to"] not in ranked:
                ranked[link["to"]] = (1, 0 if link["to"] in compiled else 1, link["to"])
        out[ui_map] = sorted(ranked, key=lambda m: ranked[m])
    return out


def _member_point(points: list[tuple[int, float, float]], area: int) -> tuple[float, float] | None:
    inside = sorted((x, y) for z, x, y in points if z == area)
    return inside[0] if inside else None


def _hubs(
    zone: Zone,
    compiled: dict[int, list[int]],
    ctx: ShapeContext,
    raw: RawData,
    faction: str,
    config: WorldConfig,
) -> list[dict[str, Any]]:
    members: dict[tuple[str, int], HubMember] = {}
    for qids in compiled.values():
        for qid in qids:
            info = ctx.quests[qid]
            for role, refs in (("start", info.starters), ("end", info.finishers)):
                for ref in refs:
                    if ref[0] not in ("n", "o"):
                        continue
                    pos = _member_point(ctx.entity_points(ref), zone.area)
                    if pos is None:
                        continue
                    member = members.setdefault(ref, HubMember(ref, pos[0], pos[1]))
                    (member.starts if role == "start" else member.ends).add(qid)
    hubs = cluster_hubs(list(members.values()), config.hub_eps, zone.key)
    levels: dict[int, int] = {}
    for qid in (q for qids in compiled.values() for q in qids):
        levels[qid] = int(ctx.quests[qid].level)
    for hub in hubs:
        name = settlement_name(faction, raw.zone_by_name, zone.area, hub["x"], hub["y"])
        hub["name"] = name or f"{zone.name} {round(hub['x'])},{round(hub['y'])}"
        lv = sorted(levels[q] for q in hub.get("qs", []) if q in levels)
        if lv:
            hub["lv"] = [lv[0], lv[-1]]
    return hubs


def _hub_services(
    hub: dict[str, Any],
    zone: Zone,
    services: ServiceIndex,
    near: dict[int, list[int]],
    area_of_ui: dict[int | None, int],
    config: WorldConfig,
) -> None:
    sv: dict[str, Any] = {}
    gaps: list[str] = []
    for role in HUB_SERVICE_ROLES:
        found = services.nearest(zone.area, hub["x"], hub["y"], role)
        if found is not None:
            (_kind, ident), d = found
            sv[role] = {"id": ident, "d": round(d, 1)}
            if role in config.required_hub_roles and d > config.service_nearby:
                gaps.append(role)
            continue
        if role in config.required_hub_roles:
            gaps.append(role)
        for other in near.get(zone.ui_map, []):
            area = area_of_ui.get(other)
            if area is not None and services.providers(area, role):
                sv[role] = {"m": other}
                break
    hub["sv"] = sv
    if gaps:
        hub["gap"] = sorted(gaps)


def _index(
    zones: list[Zone],
    tables: dict[int, dict[str, Any]],
    quest_zone: dict[int, int],
    entity_zone: dict[tuple[str, int], int],
    graph: QuestGraph,
    equivalents: list[list[int]],
) -> dict[str, Any]:
    zone_rows: dict[int, dict[str, Any]] = {}
    for zone in zones:
        meta = tables[zone.ui_map]["meta"]
        row: dict[str, Any] = {
            "area": zone.area,
            "file": zone.file_stem,
            "key": zone.key,
            "n": zone.name,
            "q": len(tables[zone.ui_map]["quests"]),
        }
        if "lv" in meta:
            row["lv"] = meta["lv"]
        zone_rows[zone.ui_map] = row
    zone_rows[OUTSIDE] = {"file": "Outside", "key": "outside", "n": "Outside compiled zones"}
    groups: dict[int, list[int]] = defaultdict(list)
    for gid, ids in graph.exclusive_groups().items():
        if any(q in quest_zone for q in ids):
            groups[gid] = ids
    return {
        "eq": equivalents,
        "ex": dict(sorted(groups.items())),
        "npcs": {i: z for (k, i), z in sorted(entity_zone.items()) if k == "n"},
        "objects": {i: z for (k, i), z in sorted(entity_zone.items()) if k == "o"},
        "quests": dict(sorted(quest_zone.items())),
        "zones": dict(sorted(zone_rows.items())),
    }


def dungeon_entrances(raw: RawData, areas: set[int]) -> dict[int, dict[str, Any]]:
    """Dungeon area id -> ``{n = name, at = {{uiMap, x, y}, ...}}`` from ``zones.json``
    dungeons. Rows are ``{"1": name, "4": [[zone, x, y], ...]}`` or
    ``[name, ids, zone, [[zone, x, y]]]``."""
    out: dict[int, dict[str, Any]] = {}
    rows = raw.zones.get("dungeons", {})
    for area in sorted(areas):
        row = rows.get(str(area))
        if isinstance(row, dict):
            name, points = row.get("1"), row.get("4")
        elif isinstance(row, list) and len(row) >= 4:
            name, points = row[0], row[3]
        else:
            continue
        entry: dict[str, Any] = {"n": str(name or raw.zone_name(area))}
        at = [p for p in (_point(int(z), x, y) for z, x, y in points or []) if p is not None]
        if at:
            entry["at"] = at
        out[area] = entry
    return out
