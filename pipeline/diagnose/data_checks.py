"""Offline data checks over the Horde routes and the QuestieDB extract (phase 18).

Each check is a pure function over the route JSON (``routes/<faction>/*.route.json``) and a
``World``; it returns a list of plain dict findings, sorted, so the report is deterministic. They
look for the data problems behind the level 15 Hunter report (docs/DYNAMIC_GUIDE_PLAN.md s1):

* ``scope_gaps``      a COMPLETE or TURNIN that applies to a race/class on a start path with no
                      ACCEPT for that quest earlier on the path, and quests turned in twice.
* ``npc_positions``   step NPCs that are missing, have no usable spawn, have spawns far apart in
                      the step's zone, or appear at different places in different steps.
* ``shadowed_ids``    route quests that share their name with another Horde-available quest id
                      (a Forever re-implementation or a per-race copy): the server may use the
                      other id, so the route's id would never be flagged completed.
* ``cross_branch_rewards``  key-reward steps outside a branch's own path that still apply to its
                      races; the legacy login audit offers them (hypothesis H2c).
* ``zone_flow``       per route, how often the steps change zone and come back to a zone already
                      left (evidence for the ordering hypothesis H3).

``run_checks`` runs them all; ``format_report`` prints a short text summary.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Callable
from pathlib import Path
from typing import Any

from pipeline.routes.validate_route import load_route_dir
from pipeline.routes.world import World, distance

# Classes the Horde races can play on Forever (route steps use these tokens).
HORDE_CLASSES: tuple[str, ...] = (
    "DRUID",
    "HUNTER",
    "MAGE",
    "PALADIN",
    "PRIEST",
    "ROGUE",
    "SHAMAN",
    "WARLOCK",
    "WARRIOR",
)
SPAWN_SPREAD = 10.0  # map-%: spawns of one NPC further apart than this in one zone are ambiguous
STEP_SPREAD = 3.0  # map-%: one NPC placed this far apart in two steps is inconsistent
CUSTOM_ID_FLOOR = 90000  # Forever's own quests use ids from here up

Finding = dict[str, Any]


def _applies(step: dict[str, Any], race: str, klass: str) -> bool:
    races = step.get("races")
    classes = step.get("classes")
    if races and race not in races:
        return False
    if classes and klass not in classes:
        return False
    return True


def branch_paths(routes: dict[str, dict[str, Any]], world: World) -> dict[str, list[str]]:
    """Start branch id -> route ids from its 01-05 band along ``next`` (stops at a missing id)."""
    starts: dict[str, str] = {}
    for rid, route in routes.items():
        band = route.get("band") or [0, 0]
        if band[0] == 1 and route.get("branch") != world.faction.shared_track:
            starts[route["branch"]] = rid
    out: dict[str, list[str]] = {}
    for branch, rid in sorted(starts.items()):
        path: list[str] = []
        current: str | None = rid
        while current and current in routes and current not in path:
            path.append(current)
            current = routes[current].get("next")
        out[branch] = path
    return out


def _branch_races(world: World, branch: str) -> tuple[str, ...]:
    try:
        return world.faction.branch(branch).races
    except KeyError:
        return ()


# ---- scope gaps ------------------------------------------------------------------------------


def scope_gaps(routes: dict[str, dict[str, Any]], world: World) -> list[Finding]:
    """COMPLETE/TURNIN steps a race+class meets before any ACCEPT of the quest on its path, and
    quests turned in twice on one path. One finding per (route, step index, kind)."""
    hits: dict[tuple[str, int, str], dict[str, Any]] = {}
    for branch, path in branch_paths(routes, world).items():
        for race in _branch_races(world, branch):
            for klass in HORDE_CLASSES:
                accepted: set[int] = set()
                turned: set[int] = set()
                for rid in path:
                    for index, step in enumerate(routes[rid].get("steps", [])):
                        quest = step.get("quest")
                        kind = step.get("type")
                        if not quest or not _applies(step, race, klass):
                            continue
                        problem = None
                        if kind == "ACCEPT":
                            accepted.add(quest)
                        elif kind in ("COMPLETE", "TURNIN") and quest not in accepted:
                            problem = "no-accept-before"
                        if kind == "TURNIN":
                            if quest in turned:
                                problem = "turned-in-twice"
                            turned.add(quest)
                        if problem:
                            key = (rid, index, problem)
                            hit = hits.setdefault(
                                key,
                                {
                                    "route": rid,
                                    "step": index,
                                    "type": kind,
                                    "quest": quest,
                                    "title": step.get("title") or world.quest_name(quest),
                                    "problem": problem,
                                    "who": set(),
                                },
                            )
                            hit["who"].add(f"{race}/{klass}")
    out = []
    for key in sorted(hits):
        hit = hits[key]
        who = sorted(hit.pop("who"))
        hit["who"] = who if len(who) <= 6 else who[:6] + [f"+{len(who) - 6} more"]
        out.append(hit)
    return out


# ---- NPC positions ---------------------------------------------------------------------------


def npc_positions(routes: dict[str, dict[str, Any]], world: World) -> list[Finding]:
    """Missing NPCs, NPCs without spawns, spawns far apart in the step's zone, and one NPC placed
    at different spots by different steps."""
    out: list[Finding] = []
    placed: dict[int, list[tuple[str, int, str, float, float]]] = defaultdict(list)
    for rid in sorted(routes):
        for index, step in enumerate(routes[rid].get("steps", [])):
            npc = step.get("npc")
            if not npc:
                continue
            base = {"route": rid, "step": index, "npc": npc, "quest": step.get("quest")}
            record = world.npcs.get(npc)
            if record is None:
                out.append({**base, "problem": "npc-not-in-db"})
                continue
            spawns = world.entity_spawns("n", npc)
            if not spawns:
                out.append({**base, "problem": "npc-no-spawns", "name": record.get("name")})
                continue
            zone = world.zone_id(step.get("zone", ""))
            here = [s for s in spawns if s[0] == zone]
            spread = max(
                (distance(a[1], a[2], b[1], b[2]) for a in here for b in here), default=0.0
            )
            if spread > SPAWN_SPREAD:
                out.append(
                    {
                        **base,
                        "problem": "spawns-far-apart",
                        "name": record.get("name"),
                        "spread": round(spread, 1),
                        "spawns": len(here),
                    }
                )
            if "x" in step and "y" in step:
                placed[npc].append((rid, index, step.get("zone", ""), step["x"], step["y"]))
    for npc in sorted(placed):
        spots = placed[npc]
        first = spots[0]
        for other in spots[1:]:
            same_zone = other[2] == first[2]
            if same_zone and distance(first[3], first[4], other[3], other[4]) > STEP_SPREAD:
                out.append(
                    {
                        "route": other[0],
                        "step": other[1],
                        "npc": npc,
                        "quest": None,
                        "problem": "npc-placed-differently",
                        "name": world.npcs.get(npc, {}).get("name"),
                        "vs": f"{first[0]}#{first[1]}",
                    }
                )
    return sorted(out, key=lambda f: (f["problem"], f["route"], f["step"]))


# ---- shadowed ids ----------------------------------------------------------------------------


def shadowed_ids(routes: dict[str, dict[str, Any]], world: World) -> list[Finding]:
    """Route quests whose name is shared with other Horde-available quest ids."""
    by_name: dict[str, set[int]] = defaultdict(set)
    for qid, quest in world.quests.items():
        if world.faction_available(quest):
            by_name[str(quest.get("name", ""))].add(qid)
    in_routes: set[int] = set()
    for route in routes.values():
        for step in route.get("steps", []):
            if step.get("quest"):
                in_routes.add(int(step["quest"]))
    out: list[Finding] = []
    seen: set[tuple[int, ...]] = set()
    for qid in sorted(in_routes):
        name = world.quest_name(qid)
        group = tuple(sorted(by_name.get(name, set()) | {qid}))
        if len(group) < 2 or group in seen:
            continue
        seen.add(group)
        custom = [q for q in group if q >= CUSTOM_ID_FLOOR]
        classic = [q for q in group if q < CUSTOM_ID_FLOOR]
        out.append(
            {
                "name": name,
                "ids": list(group),
                "inRoutes": [q for q in group if q in in_routes],
                "kind": "classic-and-custom" if custom and classic else "same-name",
            }
        )
    return sorted(out, key=lambda f: (f["kind"], f["ids"]))


# ---- cross-branch rewards ---------------------------------------------------------------------


def cross_branch_rewards(routes: dict[str, dict[str, Any]], world: World) -> list[Finding]:
    """Key-reward steps (``reward.preferItem``) in routes outside a branch's path that apply to at
    least one of the branch's races: the legacy audit can offer them to that branch."""
    paths = branch_paths(routes, world)
    out: list[Finding] = []
    for branch, path in sorted(paths.items()):
        races = _branch_races(world, branch)
        on_path = set(path)
        for rid in sorted(routes):
            if rid in on_path:
                continue
            for index, step in enumerate(routes[rid].get("steps", [])):
                reward = step.get("reward") or {}
                if not reward.get("preferItem") or not step.get("quest"):
                    continue
                who = [r for r in races if not step.get("races") or r in step["races"]]
                if who:
                    out.append(
                        {
                            "branch": branch,
                            "route": rid,
                            "step": index,
                            "quest": step["quest"],
                            "title": step.get("title") or world.quest_name(step["quest"]),
                            "zone": step.get("zone"),
                            "races": who,
                            "classes": step.get("classes") or [],
                        }
                    )
    return out


# ---- zone flow -------------------------------------------------------------------------------


def zone_flow(
    routes: dict[str, dict[str, Any]],
    world: World,
    race: str | None = None,
    klass: str | None = None,
) -> list[Finding]:
    """Per route: zones in visiting order, zone changes, and returns to a zone already left.
    With ``race`` and ``klass``, only the steps that apply to that character count."""
    out: list[Finding] = []
    for rid in sorted(routes):
        order: list[str] = []
        for step in routes[rid].get("steps", []):
            if race and klass and not _applies(step, race, klass):
                continue
            zone = step.get("zone")
            if zone and (not order or order[-1] != zone):
                order.append(zone)
        returns = sum(1 for i, z in enumerate(order) if z in order[:i])
        out.append(
            {
                "route": rid,
                "zones": len(set(order)),
                "changes": max(0, len(order) - 1),
                "returns": returns,
                "order": order,
            }
        )
    return out


CHECKS: dict[str, Callable[[dict[str, dict[str, Any]], World], list[Finding]]] = {
    "scope_gaps": scope_gaps,
    "npc_positions": npc_positions,
    "shadowed_ids": shadowed_ids,
    "cross_branch_rewards": cross_branch_rewards,
    "zone_flow": zone_flow,
}


def run_checks(
    routes: dict[str, dict[str, Any]],
    world: World,
    only: list[str] | None = None,
    as_char: tuple[str, str] | None = None,
) -> dict[str, list[Finding]]:
    """Run the named checks (default: all). ``as_char`` (race, class) filters ``zone_flow``."""
    names = only or list(CHECKS)
    out: dict[str, list[Finding]] = {}
    for name in names:
        if name == "zone_flow" and as_char:
            out[name] = zone_flow(routes, world, as_char[0], as_char[1])
        else:
            out[name] = CHECKS[name](routes, world)
    return out


def load_routes(routes_dir: Path) -> dict[str, dict[str, Any]]:
    """Every ``*.route.json`` in a folder by id, without sample routes."""
    return {
        rid: r
        for rid, r in load_route_dir(routes_dir).items()
        if not r.get("sample") and not rid.startswith("_")
    }


def format_report(results: dict[str, list[Finding]], limit: int = 25) -> str:
    lines: list[str] = []
    for name, findings in results.items():
        lines.append(f"== {name}: {len(findings)} finding(s)")
        for finding in findings[:limit]:
            lines.append("  " + ", ".join(f"{k}={v}" for k, v in finding.items()))
        if len(findings) > limit:
            lines.append(f"  ... {len(findings) - limit} more (use --json for all)")
    return "\n".join(lines)
