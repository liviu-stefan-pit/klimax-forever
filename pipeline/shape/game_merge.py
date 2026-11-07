"""Merge game-extracted transport facts (``data/raw/game/transport.json``) into travel.json.

Run by ``python -m pipeline shape`` after :func:`pipeline.shape.travel.build_travel`, and only
when ``data/raw/game/transport.json`` exists (made by ``python -m pipeline game-data``). Without
it travel.json keeps its hand-typed ``manual`` section and derived node names.

What changes:

* ``flightMasters[].nodeName``: the game's flight point label (Leatrix_Maps) when a point lies
  within :data:`FLIGHT_MATCH_DISTANCE` map-% in the same map. Then ``verified`` is true.
* ``transport.links``: Horde and neutral boat, zeppelin and portal docks with coordinates, each
  with ``source`` and ``verified`` (true = the game data names the same destination).
* ``manual.zeppelinRoutes`` / ``boatRoutes`` entries get ``verified`` and, when found, ``docks``.
* ``manual.adjacency`` entries get ``gameNeighbor`` (GatherLite lists the two maps as spatial
  neighbours; that is a rectangle test, not a road, so it never sets ``verified``).
* ``gameCheck.contradictions``: hand-typed values the game data disagrees with (both values).
"""

from __future__ import annotations

import math
from typing import Any

from pipeline.routes.ui_maps import ui_map_for

FLIGHT_MATCH_DISTANCE = 5.0
LEATRIX_SOURCE = "Leatrix_Maps/Leatrix_Maps_Icons.lua"
ZONE_TREE_SOURCE = "GatherLite/scripts/maps/zone-neighbors.lua"
FACTION_NAMES = {"horde": ("Horde", "Neutral")}

# Hand-typed route endpoints -> the zone enum they stand in (travel.json manual routes name
# sites, not zones).
SITE_ZONE = {
    "Orgrimmar Zeppelin Tower": "DUROTAR",
    "Undercity Zeppelin Tower": "TIRISFAL_GLADES",
    "Grom'gol Base Camp": "STRANGLETHORN_VALE",
    "Ratchet": "THE_BARRENS",
    "Booty Bay": "STRANGLETHORN_VALE",
}


def _zone_index(travel: dict[str, Any]) -> dict[int, dict[str, Any]]:
    """uiMapID -> travel.json zone row."""
    out: dict[int, dict[str, Any]] = {}
    for zone in travel["zones"]:
        ui_map = ui_map_for(zone["id"])
        if ui_map:
            out[ui_map] = zone
    return out


def _flight_names(
    travel: dict[str, Any], transport: dict[str, Any], factions: tuple[str, ...]
) -> None:
    points = [p for p in transport["flightPoints"] if p["faction"] in factions]
    for master in travel["flightMasters"]:
        ui_map = ui_map_for(master["zone"])
        best: tuple[float, dict[str, Any]] | None = None
        for point in points:
            if point["uiMapId"] != ui_map:
                continue
            dist = math.hypot(point["x"] - master["x"], point["y"] - master["y"])
            if best is None or dist < best[0]:
                best = (dist, point)
        if best and best[0] <= FLIGHT_MATCH_DISTANCE:
            master["nodeName"] = best[1]["label"]
            master["nodeNameSource"] = f"{LEATRIX_SOURCE} (flight point label)"
            master["verified"] = True
        else:
            master["verified"] = False


def _links(
    travel: dict[str, Any], transport: dict[str, Any], factions: tuple[str, ...]
) -> list[dict[str, Any]]:
    zones = _zone_index(travel)
    out: list[dict[str, Any]] = []
    for link in transport["links"]:
        if link["faction"] not in factions or link["mode"] is None:
            continue
        zone = zones.get(link["uiMapId"])
        dest = zones.get(link["destUiMapId"])
        out.append(
            {
                "kind": link["mode"],
                "faction": link["faction"],
                "from": {
                    "zone": zone["enum"] if zone else None,
                    "zoneId": zone["id"] if zone else None,
                    "uiMapId": link["uiMapId"],
                    "x": link["x"],
                    "y": link["y"],
                },
                "to": {
                    "place": link["place"],
                    "zone": dest["enum"] if dest else None,
                    "zoneId": dest["id"] if dest else None,
                    "uiMapId": link["destUiMapId"],
                },
                "label": link["label"],
                "source": LEATRIX_SOURCE,
                "verified": True,
            }
        )
    out.sort(
        key=lambda r: (r["from"]["uiMapId"], r["to"]["uiMapId"] or 0, r["kind"], r["from"]["x"])
    )
    return out


def _check_routes(
    travel: dict[str, Any], links: list[dict[str, Any]], contradictions: list[dict[str, Any]]
) -> None:
    zones = {z["enum"]: z for z in travel["zones"]}
    manual = travel["manual"]
    for key, kind in (("zeppelinRoutes", "zeppelin"), ("boatRoutes", "boat")):
        for route in manual.get(key, []):
            a, b = SITE_ZONE.get(route["from"]), SITE_ZONE.get(route["to"])
            if a is None or b is None or a not in zones or b not in zones:
                route["verified"] = False
                continue
            forward = [
                lk for lk in links
                if lk["kind"] == kind and lk["from"]["zone"] == a and lk["to"]["zone"] == b
            ]
            back = [
                lk for lk in links
                if lk["kind"] == kind and lk["from"]["zone"] == b and lk["to"]["zone"] == a
            ]
            route["verified"] = bool(forward and back)
            if forward or back:
                route["docks"] = {
                    "from": [lk["from"] for lk in forward],
                    "to": [lk["from"] for lk in back],
                }
            if not route["verified"]:
                contradictions.append(
                    {
                        "what": f"{key}: {route['from']} -> {route['to']}",
                        "handTyped": "route exists in both directions",
                        "game": f"{len(forward)} link(s) there, {len(back)} link(s) back",
                    }
                )
            route.pop("note", None)


def _check_adjacency(
    travel: dict[str, Any], transport: dict[str, Any], contradictions: list[dict[str, Any]]
) -> None:
    tree = transport["zoneTree"]
    ui_by_enum = {z["enum"]: ui_map_for(z["id"]) for z in travel["zones"]}
    for pair in travel["manual"]["adjacency"]:
        a, b = ui_by_enum.get(pair["a"]), ui_by_enum.get(pair["b"])
        if not a or not b:
            pair["gameNeighbor"] = None
            continue
        neighbours = tree.get(str(a), {}).get("neighbors", [])
        pair["gameNeighbor"] = b in neighbours
        if not pair["gameNeighbor"]:
            contradictions.append(
                {
                    "what": f"adjacency: {pair['a']} - {pair['b']}",
                    "handTyped": pair["via"],
                    "game": f"{ZONE_TREE_SOURCE} does not list map {b} as a neighbour of {a}",
                }
            )


def merge_game_transport(
    travel: dict[str, Any], transport: dict[str, Any], faction: str = "horde"
) -> dict[str, Any]:
    """Update ``travel`` in place and return it."""
    factions = FACTION_NAMES[faction]
    contradictions: list[dict[str, Any]] = []
    _flight_names(travel, transport, factions)
    links = _links(travel, transport, factions)
    _check_routes(travel, links, contradictions)
    _check_adjacency(travel, transport, contradictions)
    travel["transport"] = {
        "note": "Docks and flight point names read from the installed game's add-ons "
        "(python -m pipeline game-data). Coordinates are map-% on the `from` map.",
        "sources": transport["sources"][:2],
        "links": links,
    }
    travel["gameCheck"] = {"contradictions": sorted(contradictions, key=lambda r: r["what"])}
    travel["_note"] = (
        "Generated by `python -m pipeline shape` from data/raw. Everything under `manual` is "
        "hand-typed unless marked `verified`. flightMasters are candidates (subName + friendly to "
        "the faction); nodeName comes from the game's flight point labels when `verified` is true, "
        "else it is derived. `transport` and `gameCheck` come from data/raw/game/transport.json."
    )
    return travel
