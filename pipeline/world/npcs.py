"""NPC, object and item records, and the home zone that decides which file holds each one.

Home zone: the zone with the most usable spawns (ties: lower area id). An entity with no usable
spawn is homed with the first compiled quest that references it. Each NPC and object is defined
in exactly one generated file (the graph validator checks this).

Positions are kept only for entities a player walks up to (quest givers, turn-ins, services,
objects); for a mob that is only an objective target the quest objective already carries the
spawn clusters, so its record holds name, levels and rank.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Callable
from typing import Any

from pipeline.shape.coords import ZPoint, cluster_spawns, valid_spawns
from pipeline.shape.data import RawData

PointFn = Callable[[int, float, float], "list[Any] | None"]


def home_area(points: list[ZPoint]) -> int | None:
    if not points:
        return None
    counts = Counter(p[0] for p in points)
    return sorted(counts, key=lambda a: (-counts[a], a))[0]


def positions(points: list[ZPoint], point: PointFn, limit: int) -> list[list[Any]]:
    """Up to ``limit`` spawn cluster centres as ``[uiMap, x, y]`` (biggest cluster first)."""
    clusters, _total = cluster_spawns(points, max_clusters=limit)
    out: list[list[Any]] = []
    for c in clusters:
        pos = point(c.zone, round(c.x, 2), round(c.y, 2))
        if pos is not None:
            out.append(pos)
    return out


def npc_record(
    raw: RawData,
    nid: int,
    *,
    roles: list[str] | None,
    with_points: bool,
    point: PointFn,
    limit: int,
    override: list[Any] | None = None,
) -> dict[str, Any]:
    npc = raw.npcs.get(nid, {})
    lo, hi = int(npc.get("minLevel", 0)), int(npc.get("maxLevel", 0))
    out: dict[str, Any] = {"n": str(npc.get("name", "")), "lv": [lo, hi]}
    if int(npc.get("rank", 0)):
        out["rk"] = int(npc["rank"])
    friendly = npc.get("friendlyToFaction")
    if friendly:
        out["fr"] = str(friendly)
    if roles:
        out["r"] = list(roles)
        if npc.get("subName"):
            out["sub"] = str(npc["subName"])
    if override is not None:
        out["p"] = [override]
        out["fix"] = True
    elif with_points:
        pts = positions(valid_spawns(npc.get("spawns")), point, limit)
        if pts:
            out["p"] = pts
    return out


def object_record(
    raw: RawData, oid: int, *, roles: list[str] | None, point: PointFn, limit: int
) -> dict[str, Any]:
    obj = raw.objects.get(oid, {})
    out: dict[str, Any] = {"n": str(obj.get("name", ""))}
    if roles:
        out["r"] = list(roles)
    pts = positions(valid_spawns(obj.get("spawns")), point, limit)
    if pts:
        out["p"] = pts
    return out


def item_record(raw: RawData, iid: int) -> dict[str, Any]:
    item = raw.items.get(iid, {})
    out: dict[str, Any] = {
        "n": str(item.get("name", "")),
        "c": int(item.get("class") or 0),
        "s": int(item.get("subClass") or 0),
    }
    if int(item.get("itemLevel") or 0):
        out["il"] = int(item["itemLevel"])
    if int(item.get("requiredLevel") or 0):
        out["rl"] = int(item["requiredLevel"])
    return out
