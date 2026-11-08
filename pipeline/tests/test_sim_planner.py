"""The Python planner mirror runs the same vectors as tests/lua/planner_spec.lua (phase 21)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pipeline.sim import planner as pl

VECTORS = Path("tests/vectors/planner")
NAMES = [
    "hub", "ready_here", "zone_change", "chain", "tie_break", "equivalent",
    "cluster", "relocate", "stable",
]


def _vector(name: str) -> dict:
    return json.loads((VECTORS / f"{name}.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("name", NAMES)
def test_vector_matches_expected_plan(name: str) -> None:
    v = _vector(name)
    wt, level_xp = pl.weights_for(v.get("weights"))
    steps = pl.build(
        pl.world_from_vector(v),
        pl.state_from_vector(v),
        v["snapshot"],
        wt,
        level_xp=level_xp,
        prior=set(v["prior"]) if v.get("prior") else None,
    )
    assert [s["k"] for s in steps] == v["expect"], v["name"]
    for key, at in (v.get("expectAt") or {}).items():
        step = next(s for s in steps if s["k"] == key)
        assert [step["x"], step["y"]] == at, key


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


def test_spine_factor_matches_the_lua_rules() -> None:
    from pipeline.sim.planner import spine_factor

    wt = {
        "spine": {
            "rows": [[1411, 1, 12], [1413, 10, 24]],
            "on": 1.15,
            "off": 0.6,
            "boost": {840: 1.3},
            "dungeons": [{"m": 1413, "lo": 17, "hi": 24}],
            "window": 1.5,
        }
    }
    assert spine_factor({"q": 1, "m": 1411}, 5, {}) == 1.0
    assert spine_factor({"q": 1, "m": 1411}, 5, wt) == 1.15
    assert spine_factor({"q": 1, "m": 1411}, 14, wt) == 0.6
    assert spine_factor({"q": 1, "m": 1412}, 5, wt) == 0.6
    assert abs(spine_factor({"q": 840, "m": 1411}, 5, wt) - 1.15 * 1.3) < 1e-9
    dungeon = {"q": 2, "m": 1413, "flags": ["dungeon"]}
    assert abs(spine_factor(dungeon, 20, wt) - 1.15 * 1.5) < 1e-9
    assert spine_factor(dungeon, 12, wt) == 1.15


LEARN = json.loads(Path("tests/vectors/learn.json").read_text(encoding="utf-8"))


def test_learning_matches_the_shared_vector() -> None:
    entry = None
    for x, want in zip(LEARN["samples"], LEARN["means"], strict=True):
        entry = pl.learn_update(entry, x, LEARN["default"])
        assert entry["m"] == pytest.approx(want, abs=1e-9)
    assert entry["n"] == len(LEARN["samples"])
    for case in LEARN["apply"]:
        wt, _ = pl.weights_for_profile(None, case["learned"])
        assert wt["objective"] == pytest.approx(case["objective"], abs=1e-9), case["name"]


def test_shared_camp_discounts_the_second_objective_and_prior_is_marked() -> None:
    qs = {
        1: {"n": "One", "lv": 2, "rl": 1, "xp": 100, "sn": [10], "en": [10],
            "o": [{"k": "c", "at": [[1, 70.0, 50.0, 2.0, 8]]}]},
        2: {"n": "Two", "lv": 2, "rl": 1, "xp": 100, "sn": [10], "en": [10],
            "o": [{"k": "c", "at": [[1, 73.0, 50.0, 2.0, 8]]}]},
    }
    v = {
        "snapshot": {"level": 2, "xp": 0, "mapID": 1, "x": 50.0, "y": 50.0},
        "world": {"zones": {"1": {"lv": [1, 3, 6], "quests": [1, 2]}}, "quests": qs,
                  "npcs": {"10": [[1, 10.0, 50.0]]}, "objects": {},
                  "travel": {"adj": [], "links": [], "nodes": {}, "cost": {"zoneBorder": 60}}},
        "states": {"1": ["active"], "2": ["active"]},
    }
    wt, lx = pl.weights_for()
    world, state = pl.world_from_vector(v), pl.state_from_vector(v)
    steps = pl.build(world, state, v["snapshot"], wt, level_xp=lx)
    c = {s["k"]: s for s in steps}
    shared = [k for k in ("plan:C:1", "plan:C:2") if c[k]["why"]["shared"]]
    assert len(shared) == 1  # whichever is worked second shares the camp of the first
    assert c[shared[0]]["why"]["time"] == pytest.approx(wt["objective"] * wt["shareTime"])
    again = pl.build(pl.world_from_vector(v), pl.state_from_vector(v), v["snapshot"], wt,
                     level_xp=lx, prior={"plan:C:2"})
    assert next(s for s in again if s["k"] == "plan:C:2")["why"]["kept"]
