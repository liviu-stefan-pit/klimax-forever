"""Travel graph for the runtime: flight nodes, boat and zeppelin docks, zone adjacency, costs.

Built from ``data/<faction>/travel.json`` (phase 02 shape plus the phase 03b game-data merge in
``shape/game_merge.py``). Nothing new is typed here: costs come from :mod:`pipeline.world.config`
and are rough placeholders for the planner (phase 21 tunes them).
"""

from __future__ import annotations

from typing import Any

from pipeline.routes.ui_maps import ui_map_for
from pipeline.shape.data import RawData


def build_travel(travel: dict[str, Any], raw: RawData, costs: dict[str, int]) -> dict[str, Any]:
    nodes: dict[int, dict[str, Any]] = {}
    for fm in travel.get("flightMasters", []):
        ui_map = ui_map_for(int(fm["zone"]))
        if not ui_map:
            continue
        node: dict[str, Any] = {
            "m": ui_map,
            "x": round(float(fm["x"]), 2),
            "y": round(float(fm["y"]), 2),
            "n": str(fm.get("nodeName") or fm.get("place") or ""),
        }
        if fm.get("verified"):
            node["v"] = True
        nodes[int(fm["id"])] = node
    links: list[dict[str, Any]] = []
    for link in (travel.get("transport") or {}).get("links", []):
        if not link["from"].get("uiMapId") or not link["to"].get("uiMapId"):
            continue
        links.append(
            {
                "k": link["kind"],
                "m": int(link["from"]["uiMapId"]),
                "x": round(float(link["from"]["x"]), 2),
                "y": round(float(link["from"]["y"]), 2),
                "to": int(link["to"]["uiMapId"]),
                "l": str(link.get("label") or ""),
            }
        )
    links.sort(key=lambda r: (r["m"], r["to"], r["k"], r["x"], r["y"]))
    adjacency: set[tuple[int, int]] = set()
    for pair in (travel.get("manual") or {}).get("adjacency", []):
        a = raw.zone_by_name.get(pair["a"])
        b = raw.zone_by_name.get(pair["b"])
        ma = ui_map_for(a) if a is not None else None
        mb = ui_map_for(b) if b is not None else None
        if ma and mb and ma != mb:
            adjacency.add((min(ma, mb), max(ma, mb)))
    return {
        "adj": [list(p) for p in sorted(adjacency)],
        "cost": dict(sorted(costs.items())),
        "links": links,
        "nodes": dict(sorted(nodes.items())),
    }


def neighbours(travel_model: dict[str, Any]) -> dict[int, list[int]]:
    """uiMap -> adjacent uiMaps (walkable), sorted."""
    out: dict[int, set[int]] = {}
    for a, b in travel_model["adj"]:
        out.setdefault(a, set()).add(b)
        out.setdefault(b, set()).add(a)
    return {k: sorted(v) for k, v in sorted(out.items())}
