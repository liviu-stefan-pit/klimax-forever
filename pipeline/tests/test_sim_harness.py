"""Phase 28: the simulator over the compiled world, the golden plans, and the reconciler port."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pipeline.sim import harness as h
from pipeline.sim.reconciler import Reconciler
from pipeline.world.build import build_world, load_inputs
from pipeline.world.config import WorldConfig

RAW = Path("data/raw")
needs_raw = pytest.mark.skipif(not (RAW / "quests.json").exists(), reason="data/raw not extracted")


@pytest.fixture(scope="module")
def sw() -> h.SimWorld:
    raw, travel, corrections = load_inputs(RAW, Path("data"), "horde")
    return h.sim_world(build_world(raw, travel, corrections, WorldConfig()))


@needs_raw
@pytest.mark.parametrize("branch", sorted(h.BRANCHES))
def test_every_class_and_profile_runs_clean_from_1_to_40(sw: h.SimWorld, branch: str) -> None:
    problems: list[str] = []
    for cls in h.CLASSES:
        for profile in h.PROFILES:
            problems += h.check(h.simulate(sw, branch, cls, profile))
    assert problems == []


@needs_raw
def test_golden_plans_are_unchanged(sw: h.SimWorld) -> None:
    want = json.loads(h.GOLDEN_FILE.read_text(encoding="utf-8"))
    assert h.golden_plans(sw) == want, (
        "the plans changed: review the diff, then run `python -m pipeline.sim.harness --golden`"
    )


@needs_raw
def test_the_simulation_is_deterministic(sw: h.SimWorld) -> None:
    a = h.simulate(sw, "orc", "HUNTER", "speed", golden_levels=(1, 20))
    b = h.simulate(sw, "orc", "HUNTER", "speed", golden_levels=(1, 20))
    assert (a.golden, a.turned, a.seconds) == (b.golden, b.turned, b.seconds)


def test_check_flags_dead_ends_thin_curves_and_stuck_levels() -> None:
    ok = h.Result("orc", "WARRIOR", "relaxed", level=h.TARGET, turned=300, per_level={10: 20})
    assert h.check(ok) == []
    stuck = h.Result("orc", "WARRIOR", "relaxed", level=31, turned=200)
    assert any("stopped at level 31" in p for p in h.check(stuck))
    grinding = h.Result("orc", "WARRIOR", "relaxed", level=h.TARGET, grinds=h.MAX_GRINDS + 1)
    assert any("dead-end" in p for p in h.check(grinding))
    heavy = h.Result("orc", "WARRIOR", "relaxed", level=h.TARGET, per_level={20: 41})
    assert any("41 quests" in p for p in h.check(heavy))
    long_run = h.Result(
        "orc", "WARRIOR", "relaxed", level=h.TARGET, seconds=(h.MAX_HOURS + 1) * 3600
    )
    assert any("h of steps" in p for p in h.check(long_run))


def _snap(**over):
    snap = {"level": 10, "race": "Orc", "raceToken": "Orc", "class": "WARRIOR", "log": {},
            "completed": {}, "completedKnown": True}
    snap.update(over)
    return snap


def test_reconciler_port_gates_and_completion() -> None:
    recs = {
        1: {"rl": 5},
        2: {"rl": 5, "pa": [1]},
        3: {"rl": 20},
        4: {"rl": 1, "ra": 32},  # Tauren only
        5: {"rl": 1, "cl": 4},  # Hunter only
        6: {"rl": 1, "ex": 9},
        7: {"rl": 1, "pv": [8]},
        8: {"rl": 1},
        9: {"cx": "broken"},
    }
    groups = {9: [6, 10]}

    def make(**over):
        return Reconciler(_snap(**over), recs.get, groups.get, lambda q: None)

    r = make()
    assert r.state(1) == ("available", None)
    assert r.state(2) == ("unavailable", "prereq")
    assert r.state(3) == ("unavailable", "level")
    assert r.state(4) == ("unavailable", "race")
    assert r.state(5) == ("unavailable", "class")
    assert r.state(9) == ("broken", "curated")
    done = make(completed={1: True, 7: True})
    assert done.state(1) == ("completed", None)
    assert done.state(2) == ("available", None)
    assert done.state(8) == ("completed", None)  # implied by the later link 7
    assert make(log={6: {"complete": False}}).state(6) == ("active", None)
    assert make(log={10: {}}).state(6) == ("unavailable", "exclusive")
    assert make(skipped={1: True}).state(1) == ("ignored", "skipped")
    assert make(broken={1: True}).state(1) == ("broken", "reported")
