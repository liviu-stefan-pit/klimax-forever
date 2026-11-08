"""Curated spine (phase 25, docs/DYNAMIC_GUIDE_PLAN.md s4.1): which zones each start branch levels
in and when, key quests worth extra, and dungeon windows.

``data/<faction>/world/spine.json`` is hand-reviewed and part of the source of truth with the quest
graph and ``corrections.json``. :func:`compile_spine` turns zone enums into uiMapIDs for the add-on
(``Index.spine``); the planner multiplies a quest's value by ``onPath`` when its zone is on the
character's branch at that level, by ``offPath`` otherwise, by a boost factor for key quests, and by
``dungeonWindow`` for a dungeon's quests inside its window.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from pipeline.routes.ui_maps import ui_map_for
from pipeline.shape.data import RawData


class SpineError(ValueError):
    """The spine file names an unknown zone or has a malformed entry."""


def spine_path(data: Path, faction: str) -> Path:
    return data / faction / "world" / "spine.json"


def load_spine(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _ui_map(raw: RawData, enum: str) -> int:
    area = raw.zone_by_name.get(enum)
    ui_map = ui_map_for(area) if area is not None else None
    if not ui_map:
        raise SpineError(f"spine: unknown zone {enum!r}")
    return int(ui_map)


def _level(value: Any, where: str) -> int:
    if not isinstance(value, int) or not 1 <= value <= 60:
        raise SpineError(f"spine: bad level {value!r} in {where}")
    return value


def compile_spine(spine: dict[str, Any] | None, raw: RawData) -> dict[str, Any] | None:
    """The ``Index.spine`` table, or None without a spine file."""
    if not spine:
        return None
    branches: dict[str, list[list[int]]] = {}
    for branch, rows in sorted((spine.get("branches") or {}).items()):
        out = []
        for row in rows:
            lo = _level(row.get("from"), branch)
            hi = _level(row.get("to"), branch)
            if hi < lo:
                raise SpineError(f"spine: {branch} {row.get('zone')} ends before it starts")
            out.append([_ui_map(raw, str(row.get("zone"))), lo, hi])
        branches[branch] = out
    boost: dict[int, float] = {}
    for row in spine.get("boost") or []:
        qid = int(row["id"])
        if qid not in raw.quests:
            raise SpineError(f"spine: boost quest {qid} does not exist")
        boost[qid] = float(row.get("factor", 1.0))
    dungeons = []
    for row in spine.get("dungeons") or []:
        dungeons.append(
            {
                "n": str(row["name"]),
                "m": _ui_map(raw, str(row["zone"])),
                "lo": _level(row.get("from"), str(row["name"])),
                "hi": _level(row.get("to"), str(row["name"])),
            }
        )
    weights = spine.get("weights") or {}
    return {
        "boost": dict(sorted(boost.items())),
        "branches": branches,
        "dungeonWindow": float(weights.get("dungeonWindow", 1.0)),
        "dungeons": dungeons,
        "offPath": float(weights.get("offPath", 1.0)),
        "onPath": float(weights.get("onPath", 1.0)),
    }
