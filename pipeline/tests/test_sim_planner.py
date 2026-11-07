"""The Python planner mirror runs the same vectors as tests/lua/planner_spec.lua (phase 21)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pipeline.sim import planner as pl

VECTORS = Path("tests/vectors/planner")
NAMES = ["hub", "ready_here", "zone_change", "chain", "tie_break"]


def _vector(name: str) -> dict:
    return json.loads((VECTORS / f"{name}.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("name", NAMES)
def test_vector_matches_expected_plan(name: str) -> None:
    v = _vector(name)
    wt, level_xp = pl.weights_for(v.get("weights"))
    steps = pl.build(
        pl.world_from_vector(v), pl.state_from_vector(v), v["snapshot"], wt, level_xp=level_xp
    )
    assert [s["k"] for s in steps] == v["expect"], v["name"]


def test_every_vector_is_listed() -> None:
    files = sorted(p.stem for p in VECTORS.glob("*.json") if p.stem != "weights")
    assert files == sorted(NAMES)


def test_colour_and_xp_match_the_lua_rules() -> None:
    assert pl.colour(20, 15) == "red"
    assert pl.colour(18, 15) == "orange"
    assert pl.colour(13, 15) == "yellow"
    assert pl.colour(10, 15) == "green"
    assert pl.colour(8, 15) == "grey"
    assert pl.xp_at(1000, 10, 16) == 800
    assert pl.xp_at(333, 10, 16) == 265


def test_path_prefers_the_boat_and_flies_between_flight_masters() -> None:
    wt, _ = pl.weights_for()
    travel = {
        "cost": {"zoneBorder": 60, "boat": 300},
        "adj": [[1, 2], [2, 3]],
        "links": [{"k": "boat", "m": 1, "to": 3, "x": 10, "y": 10}],
        "nodes": {100: {"m": 1, "x": 5, "y": 5}, 101: {"m": 4, "x": 6, "y": 6}},
    }
    g = pl.graph(travel, wt)
    cost, edge = pl.path(g, 1, 3)
    assert cost == 300 and edge["via"] == "boat"
    cost, edge = pl.path(g, 1, 4)
    assert cost == wt["flight"] and edge["via"] == "flight"
    assert pl.path(g, 2, 99) == (None, None)


def test_plan_is_deterministic() -> None:
    v = _vector("hub")
    wt, level_xp = pl.weights_for()
    a = pl.build(
        pl.world_from_vector(v), pl.state_from_vector(v), v["snapshot"], wt, level_xp=level_xp
    )
    b = pl.build(
        pl.world_from_vector(v), pl.state_from_vector(v), v["snapshot"], wt, level_xp=level_xp
    )
    assert a == b
