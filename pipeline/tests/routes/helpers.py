"""Shared fixtures for the route tooling tests: a tiny synthetic game world."""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

from pipeline.routes.validate_route import Report, validate_route
from pipeline.routes.world import World
from pipeline.shape.factions import get_faction

FIXTURES = Path(__file__).parent / "fixtures"

ALLIANCE_FLAG = 1 << 32
ALLIANCE_RACES = 1 | 4 | 8 | 64


def _quest(
    name: str,
    start: int,
    finish: int | None = None,
    *,
    level: int = 1,
    required: int = 1,
    pre: list[int] | None = None,
    exclusive: list[int] | None = None,
    races: int = 0,
    classes: int = 0,
    creature: int | None = None,
) -> dict[str, Any]:
    quest: dict[str, Any] = {
        "name": name,
        "questLevel": level,
        "requiredLevel": required,
        "requiredRaces": races,
        "requiredClasses": classes,
        "startedBy": {"npcs": [start], "objects": [], "items": []},
        "finishedBy": {"npcs": [finish or start], "objects": [], "items": []},
        "objectives": {},
    }
    if pre:
        quest["preQuestSingle"] = pre
    if exclusive:
        quest["exclusiveTo"] = exclusive
    if creature:
        quest["objectives"] = {"creature": [[creature, None, 0]]}
    return quest


def build_world() -> World:
    """Durotar-like mini world. NPC 100 Kaltunk, 101 Gornek, 103 a Barrens NPC."""
    quests = {
        1: _quest("First Steps", 100, 101),
        2: _quest("Second Steps", 101, pre=[1], creature=104, level=2),
        3: _quest("Third Steps", 101, pre=[2], exclusive=[4], level=3),
        4: _quest("Fourth Steps", 101, pre=[2], exclusive=[3], level=3),
        5: _quest("Alliance Only", 101, races=ALLIANCE_FLAG | ALLIANCE_RACES),
        6: _quest("Needs Level Ten", 101, required=10, level=10),
        8: _quest("Barrens Errand", 103, level=12),
        9: _quest("Warrior Trial", 101, classes=1),
        10: _quest("Elite Hunt", 101, level=5),
        11: _quest("Big Boar", 101, creature=105, level=2),
    }
    xp = {1: [1, 1000], 2: [2, 2000], 3: [3, 2400], 8: [12, 500], 11: [2, 300]}
    spawn = {"14": [[43.29, 68.53]]}
    npcs = {
        100: {"name": "Kaltunk", "spawns": spawn, "minLevel": 1},
        101: {"name": "Gornek", "spawns": {"14": [[42.06, 68.33]]}, "minLevel": 1},
        103: {"name": "Barrens Hermit", "spawns": {"17": [[52.2, 31.0]]}, "minLevel": 10},
        104: {"name": "Mottled Boar", "spawns": {"14": [[44.2, 65.3]]}, "minLevel": 1},
        105: {"name": "Dire Boar", "spawns": {"14": [[44.0, 65.0]]}, "minLevel": 12},
    }
    travel = {
        "zones": [
            {"id": 14, "name": "Durotar", "enum": "DUROTAR", "levelRange": [1, 13]},
            {"id": 17, "name": "The Barrens", "enum": "THE_BARRENS", "levelRange": [10, 30]},
            {"id": 1637, "name": "Orgrimmar", "enum": "ORGRIMMAR", "levelRange": [1, 60]},
        ],
        "flightMasters": [
            {
                "id": 900,
                "name": "Test Flight Master",
                "nodeName": "The Crossroads, The Barrens",
                "zone": 17,
                "x": 52.4,
                "y": 30.5,
            }
        ],
        "innkeepers": [],
        "manual": {"settlements": []},
    }
    pack = {
        "hubs": [
            {"h": 1, "z": 14, "x": 42.4, "y": 68.7, "name": "Valley of Trials"},
            {"h": 2, "z": 14, "x": 51.5, "y": 41.6, "name": "Razor Hill"},
        ],
        "quests": [{"i": q, "n": quests[q]["name"]} for q in (1, 2, 3, 4)],
    }
    return World(
        faction=get_faction("horde"),
        quests=quests,
        npcs=npcs,
        objects={},
        xp=xp,
        travel=travel,
        manifest={"questiedb": {"version": "1.0.11", "build_commit": "abc123"}},
        packs={"durotar_01-05": pack},
    )


def load(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / f"{name}.route.json").read_text(encoding="utf-8"))


def validate_fixture(
    name: str, *, world: World | None = None, others: list[str] | None = None, stitched: bool = False
) -> Report:
    route = load(name)
    routes = {r["id"]: r for r in (load(o) for o in others or [])}
    return validate_route(route, world or build_world(), routes, stitched=stitched)


def codes(report: Report, severity: str | None = None) -> list[str]:
    return [i.code for i in report.issues if severity is None or i.severity == severity]


def with_pack_elite(world: World, quest: int) -> World:
    world = copy.copy(world)
    pack = copy.deepcopy(world.packs["durotar_01-05"])
    for row in pack["quests"]:
        if row["i"] == quest:
            row["fl"] = ["elite"]
    world.packs = {"durotar_01-05": pack}
    return world
