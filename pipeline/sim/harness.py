"""Simulator (phase 28, DYNAMIC_GUIDE_PLAN s8): virtual characters walk the planner over the
compiled world from level 1 to 40, applying quest XP; the harness checks what each plan promised.

A character is a race (start branch), a class and a profile. Every round it takes the plan the
add-on would build (the Python mirror in :mod:`pipeline.sim.planner`) and does every step: accept,
finish, hand in. After each step it checks:

* no step for an unknown quest, no target without a position on the map,
* no accept the reconciler would refuse (level, prerequisite, race, class, exclusive group),
* no quest taken twice and no hand-in for a quest that is not in the log,
* the level curve: quests per level stay inside a tolerance, and the sum of step costs stays sane,
* dead ends: rounds with no quest worth doing (the character then grinds a share of the level).

``python -m pipeline.sim.harness --golden`` writes the golden plans (``tests/golden/plans.json``),
``--all`` runs every race, class and profile.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from pipeline.sim import planner as pl
from pipeline.sim.reconciler import Reconciler

TARGET = 40
KILL_BONUS = 1.0  # kill XP on the way, as a share of quest XP (the harness has no mobs)
MAX_ROUNDS = 400
MAX_GRINDS = 2
GRIND_SHARE = 0.3
# Level curve tolerance: quests handed in at one level (Completionist finishes the greens).
MAX_QUESTS_PER_LEVEL = {"relaxed": 40, "speed": 40, "completionist": 90}
MAX_HOURS = 60.0  # sane total for 1 to 40 on quests alone (the cost model, not measured)

GOLDEN_FILE = Path("tests/golden/plans.json")
GOLDEN_LEVELS = (1, 10, 20, 30, 39)
GOLDEN_STEPS = 12

BRANCHES: dict[str, dict[str, Any]] = {
    "orc": {"branch": "durotar", "race": "Orc", "token": "Orc", "map": 1411, "x": 52, "y": 43},
    "troll": {
        "branch": "durotar",
        "race": "Troll",
        "token": "Troll",
        "map": 1411,
        "x": 52,
        "y": 43,
    },
    "tauren": {
        "branch": "mulgore",
        "race": "Tauren",
        "token": "Tauren",
        "map": 1412,
        "x": 45,
        "y": 60,
    },
    "undead": {
        "branch": "tirisfal",
        "race": "Undead",
        "token": "Scourge",
        "map": 1420,
        "x": 32,
        "y": 65,
    },
    "zephras": {
        "branch": "zephras",
        "race": "Orc",
        "token": "Orc",
        "map": 2521,
        "x": 40,
        "y": 40,
    },
}
CLASSES = ("WARRIOR", "HUNTER", "MAGE", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "DRUID", "PALADIN")
# Three profiles: the defaults, the Speed preset and the Completionist preset (Profile.lua).
PROFILES: dict[str, dict[str, str]] = {
    "relaxed": {},
    "speed": {"pace": "speed", "elites": "skip", "completionist": "xp"},
    "completionist": {
        "pace": "relaxed",
        "completionist": "finish",
        "elites": "allow",
        "dungeons": "good",
    },
}
# Default characters for the golden plans: (branch, class, profile).
GOLDEN_CHARACTERS = (
    ("orc", "WARRIOR", "relaxed"),
    ("troll", "HUNTER", "speed"),
    ("tauren", "DRUID", "relaxed"),
    ("undead", "MAGE", "completionist"),
    ("zephras", "SHAMAN", "relaxed"),
)


@dataclass
class SimWorld:
    """The compiled world as the planner reads it, plus the lookups the reconciler needs."""

    world: pl.World
    ex: dict[int, list[int]]
    eq: dict[int, list[int]]
    spine: dict[str, Any] | None

    def info(self, q: int) -> dict[str, Any] | None:
        return self.world.quest(q)


def sim_world(model: Any) -> SimWorld:
    """Builds the planner world from a :class:`pipeline.world.build.WorldModel`."""
    zones: dict[int, dict[str, Any]] = {}
    quests: dict[int, dict[str, Any]] = {}
    npcs: dict[int, list[list[float]]] = {}
    objects: dict[int, list[list[float]]] = {}
    for m, table in model.tables.items():
        if m != 0:
            meta = table.get("meta", {})
            zones[m] = {"lv": list(meta.get("lv") or [1, 1, 1]), "quests": sorted(table["quests"])}
            quests.update(table["quests"])
        for ident, npc in (table.get("npcs") or {}).items():
            if npc.get("p"):
                npcs[int(ident)] = npc["p"]
        for ident, obj in (table.get("objects") or {}).items():
            if obj.get("p"):
                objects[int(ident)] = obj["p"]
    travel = json.loads(json.dumps(model.travel))
    travel["nodes"] = {int(k): v for k, v in travel["nodes"].items()}
    eq: dict[int, list[int]] = {}
    for group in model.index.get("eq", []):
        for q in group:
            eq[q] = group
    return SimWorld(
        world=pl.World(
            zones=zones,
            quests=quests,
            npcs=npcs,
            objects=objects,
            travel=travel,
            xpl=model.index.get("xpl"),
        ),
        ex={int(k): list(v) for k, v in (model.index.get("ex") or {}).items()},
        eq=eq,
        spine=model.index.get("spine"),
    )


def spine_for(spine: dict[str, Any] | None, branch: str) -> dict[str, Any] | None:
    """``Planner.SpineFor``: the rows of one branch and the shared factors."""
    rows = spine and (spine.get("branches") or {}).get(branch)
    if not rows:
        return None
    return {
        "rows": rows,
        "on": spine["onPath"],
        "off": spine["offPath"],
        "boost": {int(k): v for k, v in (spine.get("boost") or {}).items()},
        "dungeons": spine.get("dungeons") or [],
        "window": spine["dungeonWindow"],
    }


@dataclass
class Result:
    branch: str
    cls: str
    profile: str
    level: int = 1
    turned: int = 0
    grinds: int = 0
    rounds: int = 0
    seconds: float = 0.0
    problems: list[str] = field(default_factory=list)
    per_level: dict[int, int] = field(default_factory=dict)  # level -> quests handed in at it
    golden: dict[int, list[str]] = field(default_factory=dict)  # level -> first plan keys

    @property
    def hours(self) -> float:
        return self.seconds / 3600.0


def _valid_target(s: dict[str, Any]) -> bool:
    x, y = s.get("x"), s.get("y")
    return bool(
        s.get("z")
        and isinstance(x, (int, float))
        and isinstance(y, (int, float))
        and 0 <= x <= 100
        and 0 <= y <= 100
    )


def simulate(
    sw: SimWorld,
    branch: str,
    cls: str,
    profile: str = "relaxed",
    target: int = TARGET,
    golden_levels: tuple[int, ...] = (),
) -> Result:
    b = BRANCHES[branch]
    res = Result(branch=branch, cls=cls, profile=profile)
    wt, level_xp = pl.weights_for_profile(PROFILES[profile])
    wt["spine"] = spine_for(sw.spine, b["branch"])
    snap: dict[str, Any] = {
        "level": 1,
        "xp": 0,
        "race": b["race"],
        "raceToken": b["token"],
        "class": cls,
        "mapID": b["map"],
        "x": b["x"],
        "y": b["y"],
        "log": {},
        "completed": {},
        "completedKnown": True,
        "skipped": {},
        "seen": {},
    }
    wanted = sorted(golden_levels)
    grinds = 0

    def fresh() -> Reconciler:
        return Reconciler(snap, sw.info, sw.ex.get, sw.eq.get)

    def level_up() -> None:
        while snap["level"] < 60 and snap["xp"] >= level_xp[snap["level"] - 1]:
            snap["xp"] -= level_xp[snap["level"] - 1]
            snap["level"] += 1

    def bad(msg: str) -> None:
        res.problems.append(f"{b['race']} {cls} L{snap['level']}: {msg}")

    def hand_in(q: int, rec: dict[str, Any]) -> None:
        del snap["log"][q]
        snap["completed"][q] = True
        res.turned += 1
        res.per_level[snap["level"]] = res.per_level.get(snap["level"], 0) + 1
        lv = rec.get("lv") if rec.get("lv") is not None else snap["level"]
        base = rec.get("xp") or (sw.world.xpl[lv - 1] if sw.world.xpl else 0)
        snap["xp"] += int((1 + KILL_BONUS) * pl.xp_at(base, lv, snap["level"]))
        level_up()

    while snap["level"] < target and res.rounds < MAX_ROUNDS and not res.problems:
        res.rounds += 1
        ctx = fresh()
        steps = pl.build(sw.world, ctx.state, snap, wt, level_xp=level_xp)
        while wanted and snap["level"] >= wanted[0]:
            res.golden[wanted.pop(0)] = [s["k"] for s in steps[:GOLDEN_STEPS]]
        worked = False
        for s in steps:
            ctx = fresh()
            if s["t"] in ("A", "C", "T"):
                q = s["q"]
                rec = sw.info(q)
                if not rec:
                    bad(f"step for unknown quest {q}")
                    break
                if not _valid_target(s):
                    bad(f"{s['k']} has no valid target")
                    break
                state = ctx.state(q)[0]
                if state == "completed":
                    bad(f"{s['k']} is for a quest already completed")
                    break
                if s["t"] == "A":
                    gate = ctx.gate(q, rec)
                    if gate or state in ("ignored", "broken"):
                        bad(f"{s['k']} cannot be accepted: {gate or state}")
                        break
                    snap["log"][q] = {"complete": True if not rec.get("o") else None}
                elif q not in snap["log"]:
                    bad(f"{s['k']} needs the quest in the log")
                    break
                elif s["t"] == "C":
                    snap["log"][q]["complete"] = True
                else:
                    hand_in(q, rec)
                worked = True
                res.seconds += (s.get("why") or {}).get("cost") or 0.0
                snap["mapID"], snap["x"], snap["y"] = s["z"], s["x"], s["y"]
            elif s["t"] == "V" and s.get("z") and s.get("x") is not None:
                snap["mapID"], snap["x"], snap["y"] = s["z"], s["x"], s["y"]
        if not worked and not res.problems:
            if grinds >= MAX_GRINDS:
                break
            grinds += 1
            snap["xp"] += int(level_xp[snap["level"] - 1] * GRIND_SHARE)
            level_up()
    res.level = snap["level"]
    res.grinds = grinds
    return res


def check(res: Result) -> list[str]:
    """Problems of a finished run, including the level-curve and playtime tolerances."""
    out = list(res.problems)
    tag = f"{res.branch} {res.cls} {res.profile}"
    if res.level < TARGET:
        out.append(f"{tag}: stopped at level {res.level} after {res.turned} quests")
    if res.grinds > MAX_GRINDS:
        out.append(f"{tag}: {res.grinds} dead-end rounds")
    for level, n in sorted(res.per_level.items()):
        if n > MAX_QUESTS_PER_LEVEL[res.profile]:
            out.append(f"{tag}: {n} quests handed in at level {level}")
    if res.hours > MAX_HOURS:
        out.append(f"{tag}: {res.hours:.0f} h of steps")
    return out


def golden_plans(sw: SimWorld) -> dict[str, Any]:
    """The plan keys of the default characters at the golden levels."""
    out: dict[str, Any] = {}
    for branch, cls, profile in GOLDEN_CHARACTERS:
        res = simulate(sw, branch, cls, profile, golden_levels=GOLDEN_LEVELS)
        out[f"{branch}-{cls.lower()}-{profile}"] = {
            str(level): res.golden.get(level, []) for level in GOLDEN_LEVELS
        }
    return out


def main() -> None:  # pragma: no cover - thin command line
    import argparse

    from pipeline.world.build import build_world, load_inputs
    from pipeline.world.config import WorldConfig

    parser = argparse.ArgumentParser(description="Simulate characters and write golden plans.")
    parser.add_argument("--golden", action="store_true", help="write tests/golden/plans.json")
    parser.add_argument("--all", action="store_true", help="run every race/class/profile")
    args = parser.parse_args()
    raw, travel, corrections = load_inputs(Path("data/raw"), Path("data"), "horde")
    sw = sim_world(build_world(raw, travel, corrections, WorldConfig()))
    if args.golden:
        GOLDEN_FILE.parent.mkdir(parents=True, exist_ok=True)
        GOLDEN_FILE.write_text(
            json.dumps(golden_plans(sw), indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(f"wrote {GOLDEN_FILE}")
    if args.all:
        total = len(BRANCHES) * len(CLASSES) * len(PROFILES)
        failed = 0
        for branch in BRANCHES:
            for cls in CLASSES:
                for profile in PROFILES:
                    problems = check(simulate(sw, branch, cls, profile))
                    failed += bool(problems)
                    for line in problems:
                        print(line)
        print(f"{total - failed} of {total} combinations clean")


if __name__ == "__main__":  # pragma: no cover
    main()
