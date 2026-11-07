"""Coordinate helpers: spawn lookup, DBSCAN clustering, hub detection.

All coordinates are map percentages (0-100) as stored by QuestieDB. The sentinel
``[-1, -1]`` marks "no known position" and is skipped everywhere (phase 01 decision).

Everything here is deterministic: inputs are sorted before clustering, and cluster order
is fixed by (size desc, zone, x, y).
"""

from __future__ import annotations

import math
from collections import defaultdict
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from typing import Any

# (zone id, x, y)
ZPoint = tuple[int, float, float]

# DBSCAN parameters (PRD §5.4 asks for eps about 4 map-%).
OBJECTIVE_EPS = 4.0
OBJECTIVE_MIN_SAMPLES = 2
MAX_OBJECTIVE_CLUSTERS = 2
HUB_EPS = 3.0
HUB_MIN_SAMPLES = 3
# A point that DBSCAN left as noise joins the nearest hub if it is closer than this.
HUB_JOIN_RADIUS = 6.0


def valid_spawns(spawns: dict[str, Any] | None) -> list[ZPoint]:
    """Flatten ``{zoneId: [[x, y(, phase)], ...]}`` into sorted ``(zone, x, y)`` points."""
    points: list[ZPoint] = []
    for zone_key, pts in (spawns or {}).items():
        try:
            zone = int(zone_key)
        except (TypeError, ValueError):
            continue
        for pt in pts or []:
            if len(pt) < 2:
                continue
            x, y = float(pt[0]), float(pt[1])
            if x < 0 or y < 0:  # [-1, -1] sentinel
                continue
            points.append((zone, x, y))
    return sorted(points)


def dist(a: tuple[float, float], b: tuple[float, float]) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def dbscan(points: Sequence[tuple[float, float]], eps: float, min_samples: int) -> list[int]:
    """Plain DBSCAN. Returns a cluster label per point, ``-1`` for noise.

    A uniform grid with cell size ``eps`` keeps neighbour lookups cheap. Points are visited in
    index order, so the labelling depends only on the input order.
    """
    n = len(points)
    cells: dict[tuple[int, int], list[int]] = defaultdict(list)
    for idx, (x, y) in enumerate(points):
        cells[(math.floor(x / eps), math.floor(y / eps))].append(idx)

    def neighbours(idx: int) -> list[int]:
        x, y = points[idx]
        cx, cy = math.floor(x / eps), math.floor(y / eps)
        found = []
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for other in cells.get((cx + dx, cy + dy), ()):
                    if dist(points[other], (x, y)) <= eps:
                        found.append(other)
        return sorted(found)

    labels = [-2] * n  # -2 unvisited, -1 noise
    cluster = 0
    for idx in range(n):
        if labels[idx] != -2:
            continue
        near = neighbours(idx)
        if len(near) < min_samples:
            labels[idx] = -1
            continue
        labels[idx] = cluster
        queue = [p for p in near if p != idx]
        while queue:
            cur = queue.pop(0)
            if labels[cur] == -1:
                labels[cur] = cluster
            if labels[cur] != -2:
                continue
            labels[cur] = cluster
            more = neighbours(cur)
            if len(more) >= min_samples:
                queue.extend(m for m in more if labels[m] in (-2, -1))
        cluster += 1
    return labels


@dataclass(frozen=True)
class Cluster:
    zone: int
    x: float
    y: float
    radius: float
    count: int

    def to_json(self) -> dict[str, Any]:
        return {
            "z": self.zone,
            "x": r1(self.x),
            "y": r1(self.y),
            "r": r1(self.radius),
            "n": self.count,
        }


def r1(value: float) -> float:
    return round(value + 0.0, 1)


def cluster_spawns(
    points: Iterable[ZPoint],
    eps: float = OBJECTIVE_EPS,
    min_samples: int = OBJECTIVE_MIN_SAMPLES,
    max_clusters: int = MAX_OBJECTIVE_CLUSTERS,
) -> tuple[list[Cluster], int]:
    """Cluster spawn points per zone and return the biggest clusters plus the total count.

    Noise points (nothing within ``eps``) become their own size-1 clusters, so a lone spawn
    is never lost. Clusters are ranked by size (desc), then zone, x, y.
    """
    by_zone: dict[int, list[tuple[float, float]]] = defaultdict(list)
    total = 0
    for zone, x, y in sorted(set(points)):
        by_zone[zone].append((x, y))
        total += 1
    clusters: list[Cluster] = []
    for zone in sorted(by_zone):
        pts = by_zone[zone]
        labels = dbscan(pts, eps, min_samples)
        groups: dict[int, list[tuple[float, float]]] = defaultdict(list)
        singles: list[tuple[float, float]] = []
        for pt, label in zip(pts, labels, strict=True):
            if label == -1:
                singles.append(pt)
            else:
                groups[label].append(pt)
        members = [groups[k] for k in sorted(groups)] + [[pt] for pt in singles]
        for group in members:
            cx = sum(p[0] for p in group) / len(group)
            cy = sum(p[1] for p in group) / len(group)
            radius = max(dist(p, (cx, cy)) for p in group)
            clusters.append(Cluster(zone, cx, cy, radius, len(group)))
    clusters.sort(key=lambda c: (-c.count, c.zone, round(c.x, 3), round(c.y, 3)))
    return clusters[:max_clusters], total


@dataclass(frozen=True)
class Hub:
    zone: int
    x: float
    y: float
    size: int


def find_hubs(
    points: Iterable[ZPoint],
    eps: float = HUB_EPS,
    min_samples: int = HUB_MIN_SAMPLES,
) -> list[Hub]:
    """Cluster unique quest-giver positions into hubs (centroid + member count)."""
    by_zone: dict[int, list[tuple[float, float]]] = defaultdict(list)
    for zone, x, y in sorted(set(points)):
        by_zone[zone].append((x, y))
    hubs: list[Hub] = []
    for zone in sorted(by_zone):
        pts = by_zone[zone]
        labels = dbscan(pts, eps, min_samples)
        groups: dict[int, list[tuple[float, float]]] = defaultdict(list)
        for pt, label in zip(pts, labels, strict=True):
            if label >= 0:
                groups[label].append(pt)
        for key in sorted(groups):
            g = groups[key]
            hubs.append(
                Hub(zone, sum(p[0] for p in g) / len(g), sum(p[1] for p in g) / len(g), len(g))
            )
    hubs.sort(key=lambda h: (h.zone, round(h.x, 3), round(h.y, 3)))
    return hubs


def nearest_hub(hubs: Sequence[Hub], point: ZPoint, radius: float | None = None) -> int | None:
    """Index of the nearest hub in the same zone (within ``radius`` if given)."""
    best: tuple[float, int] | None = None
    for idx, hub in enumerate(hubs):
        if hub.zone != point[0]:
            continue
        d = dist((hub.x, hub.y), (point[1], point[2]))
        if radius is not None and d > radius:
            continue
        if best is None or d < best[0]:
            best = (d, idx)
    return None if best is None else best[1]


def pick_spawn(candidates: Sequence[ZPoint], hubs: Sequence[Hub]) -> ZPoint | None:
    """Choose the spawn closest to a hub centroid (PRD §5.4).

    With no hub in any candidate zone the first candidate (sorted order) wins.
    """
    if not candidates:
        return None
    best: tuple[float, ZPoint] | None = None
    for cand in candidates:
        for hub in hubs:
            if hub.zone != cand[0]:
                continue
            d = dist((hub.x, hub.y), (cand[1], cand[2]))
            if best is None or d < best[0] or (d == best[0] and cand < best[1]):
                best = (d, cand)
    return best[1] if best else sorted(candidates)[0]
