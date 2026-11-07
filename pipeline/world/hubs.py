"""Hub clustering: quest givers and turn-ins that stand close together form a hub.

Input is every placed starter and finisher (NPC or object) of the compiled quests, per zone.
Points are clustered with the DBSCAN of ``shape/coords.py`` at ``eps = HUB_EPS`` and one sample,
which is single-link clustering: every giver lands in a hub, and a lone camp is a one-NPC hub.

Stable ids: a hub is named after its **anchor**, the member that starts and ends the most quests
(ties: NPC before object, then the lower id), as ``<zoneKey>:n<npcId>`` (or ``o<objectId>``). The
id survives data refreshes as long as that NPC stays in the hub, unlike a centroid or an index.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any

from pipeline.shape.coords import dbscan, dist

Ref = tuple[str, int]


@dataclass
class HubMember:
    ref: Ref
    x: float
    y: float
    starts: set[int] = field(default_factory=set)
    ends: set[int] = field(default_factory=set)


def cluster_hubs(members: list[HubMember], eps: float, zone_key: str) -> list[dict[str, Any]]:
    """Hubs of one zone, sorted by id. ``members`` must be unique per ref."""
    ordered = sorted(members, key=lambda m: (m.x, m.y, m.ref))
    labels = dbscan([(m.x, m.y) for m in ordered], eps, 1)
    groups: dict[int, list[HubMember]] = defaultdict(list)
    for member, label in zip(ordered, labels, strict=True):
        groups[label].append(member)
    hubs: list[dict[str, Any]] = []
    for group in groups.values():
        anchor = sorted(group, key=lambda m: (-(len(m.starts) + len(m.ends)), m.ref[0], m.ref[1]))[
            0
        ]
        cx = sum(m.x for m in group) / len(group)
        cy = sum(m.y for m in group) / len(group)
        radius = max(dist((m.x, m.y), (cx, cy)) for m in group)
        hub: dict[str, Any] = {
            "id": f"{zone_key}:{anchor.ref[0]}{anchor.ref[1]}",
            "x": round(cx, 2),
            "y": round(cy, 2),
            "r": round(radius, 2),
        }
        npcs = sorted(m.ref[1] for m in group if m.ref[0] == "n")
        objects = sorted(m.ref[1] for m in group if m.ref[0] == "o")
        if npcs:
            hub["npcs"] = npcs
        if objects:
            hub["objects"] = objects
        starts = sorted({q for m in group for q in m.starts})
        ends = sorted({q for m in group for q in m.ends})
        if starts:
            hub["qs"] = starts
        if ends:
            hub["qe"] = ends
        hubs.append(hub)
    hubs.sort(key=lambda h: h["id"])
    return hubs
