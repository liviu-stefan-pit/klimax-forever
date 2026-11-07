"""Python mirror of the add-on planner (``Klimax/Plan/*.lua``, phase 21).

Same formulas, same order of operations and the same tie-breakers, so a plan built here equals the
plan the add-on builds for the same world, state and snapshot. The shared vectors in
``tests/vectors/planner`` are run by both ``tests/lua/planner_spec.lua`` and
``pipeline/tests/test_sim_planner.py``; the weights come from
``tests/vectors/planner/weights.json``,
which the Lua spec keeps equal to ``Klimax/Plan/Weights.lua``.

The world interface is a :class:`World` (zone ids, zone info, zone quests, quest records, NPC and
object points, ``xpl`` and the travel table). ``state(q)`` returns ``(state, reason)``.
"""

from __future__ import annotations

import copy
import json
import math
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

WEIGHTS_FILE = Path("tests/vectors/planner/weights.json")
INF = math.inf
KIND_ORDER = {"T": 1, "C": 2, "A": 3}

StateFn = Callable[[int], tuple[str, str | None]]


def load_weights(path: Path = WEIGHTS_FILE) -> tuple[dict[str, Any], list[int]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return data["default"], list(data["levelXp"])


def merge(into: dict[str, Any], over: dict[str, Any]) -> None:
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(into.get(k), dict):
            merge(into[k], v)
        else:
            into[k] = v


# ---- world interface -----------------------------------------------------------------------------


@dataclass
class World:
    zones: dict[int, dict[str, Any]]  # uiMap -> {"lv": [lo, med, hi], "quests": [ids]}
    quests: dict[int, dict[str, Any]]
    npcs: dict[int, list[list[float]]]  # id -> [[m, x, y], ...]
    objects: dict[int, list[list[float]]]
    travel: dict[str, Any] = field(default_factory=dict)
    xpl: list[int] | None = None
    _quest_zone: dict[int, int] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for m, z in self.zones.items():
            z["quests"] = sorted(z.get("quests", []))
            for q in z["quests"]:
                self._quest_zone[q] = m

    def zone_ids(self) -> list[int]:
        return sorted(self.zones)

    def zone_info(self, m: int) -> dict[str, Any] | None:
        return self.zones.get(m)

    def zone_quests(self, m: int) -> list[int]:
        return self.zones.get(m, {}).get("quests", [])

    def quest(self, q: int) -> dict[str, Any] | None:
        return self.quests.get(q)

    def quest_zone(self, q: int) -> int | None:
        return self._quest_zone.get(q)

    def npc_points(self, ident: int) -> list[list[float]] | None:
        return self.npcs.get(ident)

    def object_points(self, ident: int) -> list[list[float]] | None:
        return self.objects.get(ident)


def _int_keys(d: dict[str, Any] | None) -> dict[int, Any]:
    return {int(k): v for k, v in (d or {}).items()}


def world_from_vector(v: dict[str, Any]) -> World:
    w = v["world"]
    travel = copy.deepcopy(w.get("travel") or {})
    travel["nodes"] = _int_keys(travel.get("nodes"))
    return World(
        zones=_int_keys(copy.deepcopy(w["zones"])),
        quests=_int_keys(w["quests"]),
        npcs=_int_keys(w.get("npcs")),
        objects=_int_keys(w.get("objects")),
        travel=travel,
        xpl=w.get("xpl"),
    )


def state_from_vector(v: dict[str, Any]) -> StateFn:
    states = _int_keys(v.get("states"))

    def state(q: int) -> tuple[str, str | None]:
        s = states.get(q)
        if s:
            return s[0], (s[1] if len(s) > 1 else None)
        return "available", None

    return state


# ---- score ---------------------------------------------------------------------------------------


def grey_range(level: int) -> int:
    if level <= 39:
        return 5 + level // 10
    return level // 5


def colour(quest_level: int | None, level: int, slack: int = 4) -> str:
    ql = level if quest_level is None else quest_level
    diff = ql - level
    if diff > slack:
        return "red"
    if diff >= 3:
        return "orange"
    if diff >= -2:
        return "yellow"
    if level - ql > grey_range(level):
        return "grey"
    return "green"


def xp_at(base: int, quest_level: int, level: int) -> int:
    diff = level - quest_level
    if diff <= 5:
        factor = 1.0
    elif diff == 6:
        factor = 0.8
    elif diff == 7:
        factor = 0.6
    elif diff == 8:
        factor = 0.4
    elif diff == 9:
        factor = 0.2
    else:
        factor = 0.1
    return math.floor(math.floor(base * factor) / 5) * 5


def dist(ax: float, ay: float, bx: float, by: float) -> float:
    dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)


def risk(flags: list[str] | None, wt: dict[str, Any]) -> float:
    m = 1.0
    for f in flags or []:
        r = wt["risk"].get(f)
        if r is not None:
            m = m * r
    return m


def value(p: dict[str, Any], level: int, wt: dict[str, Any]) -> tuple[float, dict[str, Any]]:
    col = colour(p.get("lv"), level, wt["levelSlack"])
    lv = p.get("lv") if p.get("lv") is not None else level
    xp = xp_at(p.get("xp") or 0, lv, level)
    terms: dict[str, Any] = {
        "xp": xp,
        "colour": col,
        "colourMult": wt["colour"].get(col, 0),
        "risk": risk(p.get("flags"), wt),
        "class": 1.0,
        "upgrade": 1.0,
        "chain": 1.0,
    }
    if p.get("classQuest"):
        terms["class"] = wt["classQuest"]
    if p.get("upgrade"):
        terms["upgrade"] = wt["upgrade"]
    if p.get("chain"):
        terms["chain"] = 1.0 + wt["chain"]
    v = (
        xp
        * terms["colourMult"]
        * terms["risk"]
        * terms["class"]
        * terms["upgrade"]
        * terms["chain"]
    )
    return v, terms


def obligation(stage: str, wt: dict[str, Any]) -> float:
    if stage == "T":
        return wt["obligationReady"]
    if stage == "C":
        return wt["obligationActive"]
    return 1.0


# ---- transitions ---------------------------------------------------------------------------------


def graph(travel: dict[str, Any], wt: dict[str, Any]) -> dict[int, list[dict[str, Any]]]:
    g: dict[int, list[dict[str, Any]]] = {}

    def add(a: int, b: int, cost: float, via: str, x: float | None = None, y: float | None = None):
        g.setdefault(a, []).append({"to": b, "cost": cost, "via": via, "x": x, "y": y})

    cost_table = travel.get("cost") or {}
    border = (cost_table.get("zoneBorder") or 0) + wt["hop"]
    for a, b in travel.get("adj") or []:
        add(a, b, border, "walk")
        add(b, a, border, "walk")
    for link in travel.get("links") or []:
        c = cost_table.get(link["k"])
        add(
            link["m"],
            link["to"],
            c if c is not None else wt["flight"],
            link["k"],
            link["x"],
            link["y"],
        )
    by_map: dict[int, dict[str, Any]] = {}
    for ident in sorted(travel.get("nodes") or {}):
        n = travel["nodes"][ident]
        by_map.setdefault(n["m"], n)
    maps = sorted(by_map)
    for a in maps:
        for b in maps:
            if a != b:
                add(a, b, wt["flight"], "flight", by_map[a]["x"], by_map[a]["y"])
    for edges in g.values():
        edges.sort(key=lambda e: (e["to"], e["via"]))
    return g


def path(g: dict[int, list[dict[str, Any]]], a: int, b: int) -> tuple[float | None, Any]:
    if a == b:
        return 0, None
    d: dict[int, float] = {a: 0}
    first: dict[int, dict[str, Any]] = {}
    done: set[int] = set()
    while True:
        best, best_d = None, None
        for m, dv in d.items():
            if m in done:
                continue
            if best_d is None or dv < best_d or (dv == best_d and m < best):
                best, best_d = m, dv
        if best is None:
            return None, None
        if best == b:
            return best_d, first.get(b)
        done.add(best)
        for e in g.get(best, []):
            nd = best_d + e["cost"]
            if e["to"] not in done and (e["to"] not in d or nd < d[e["to"]]):
                d[e["to"]] = nd
                first[e["to"]] = e if best == a else first[best]


def path_cache(travel: dict[str, Any], wt: dict[str, Any]) -> Callable[[int, int], Any]:
    g = graph(travel or {}, wt)
    memo: dict[tuple[int, int], Any] = {}

    def lookup(a: int, b: int) -> tuple[float | None, Any]:
        if (a, b) not in memo:
            memo[(a, b)] = path(g, a, b)
        return memo[(a, b)]

    return lookup


# ---- candidates ----------------------------------------------------------------------------------


def nearest(W: World, npcs: list[int] | None, objects: list[int] | None, pos: dict[str, Any]):
    best: dict[str, Any] | None = None
    best_d = INF

    def consider(points: list[list[float]] | None, ident: int, kind: str) -> None:
        nonlocal best, best_d
        for p in points or []:
            d = dist(p[1], p[2], pos["x"], pos["y"]) if p[0] == pos["m"] else INF
            if (
                best is None
                or d < best_d
                or (
                    d == best_d
                    and (kind < best["kind"] or (kind == best["kind"] and ident < best["id"]))
                )
            ):
                best = {"m": p[0], "x": p[1], "y": p[2], "id": ident, "kind": kind}
                best_d = d

    for ident in npcs or []:
        consider(W.npc_points(ident), ident, "n")
    for ident in objects or []:
        consider(W.object_points(ident), ident, "o")
    return best


def objective_spots(rec: dict[str, Any]) -> list[dict[str, Any]]:
    out = []
    for o in rec.get("o") or []:
        at = (o.get("at") or [None])[0]
        if at:
            out.append({"m": at[0], "x": at[1], "y": at[2], "r": at[3] if len(at) > 3 else 0})
    return out


def _neighbours(travel: dict[str, Any], m: int | None) -> set[int]:
    out: set[int] = set()
    for a, b in travel.get("adj") or []:
        if a == m:
            out.add(b)
        elif b == m:
            out.add(a)
    for link in travel.get("links") or []:
        if link["m"] == m:
            out.add(link["to"])
    return out


def zones(W: World, snap: dict[str, Any], wt: dict[str, Any], wide: bool) -> list[int]:
    level = snap.get("level") or 1
    want: set[int] = set()
    close = _neighbours(W.travel or {}, snap.get("mapID"))
    for m in W.zone_ids():
        info = W.zone_info(m)
        lv = info.get("lv") if info else None
        in_band = (
            bool(lv) and lv[2] >= level - wt["zoneBelow"] and lv[0] <= level + wt["levelSlack"]
        )
        if m == snap.get("mapID") or (in_band and (wide or m in close)):
            want.add(m)
    for q in snap.get("log") or {}:
        zm = W.quest_zone(int(q))
        if zm:
            want.add(zm)
    return sorted(want)


def stage_of(state: str | None, reason: str | None, rec: dict[str, Any]) -> tuple[str | None, bool]:
    if state in ("available", "abandoned"):
        return "A", False
    if state == "active":
        return ("T" if not rec.get("o") else "C"), False
    if state == "objectives-done":
        return "T", False
    if state == "unavailable" and reason in ("prereq", "level"):
        return "A", True
    return None, False


def packet(
    W: World,
    q: int,
    rec: dict[str, Any],
    stage: str,
    locked: bool,
    snap: dict[str, Any],
    wt: dict[str, Any],
) -> dict[str, Any] | None:
    pos = {"m": snap.get("mapID"), "x": snap.get("x") or 50, "y": snap.get("y") or 50}
    xpl = W.xpl
    lv = rec.get("lv") if rec.get("lv") is not None else snap.get("level")
    base_xp = rec.get("xp")
    if base_xp is None:
        base_xp = (xpl[(rec.get("lv") or 1) - 1] if xpl else 0) or 0
    p: dict[str, Any] = {
        "q": q,
        "n": rec.get("n"),
        "lv": lv,
        "stage": stage,
        "locked": locked,
        "pa": rec.get("pa"),
        "po": rec.get("po"),
        "rl": max(rec.get("rl") or 1, rec.get("re") or 1),
        "xp": base_xp,
        "flags": rec.get("f"),
        "classQuest": rec.get("cl") is not None,
        "upgrade": bool(rec.get("ru")),
        "chain": rec.get("nx") is not None,
        "elite": "elite" in (rec.get("f") or []),
    }
    if stage == "A":
        p["giver"] = nearest(W, rec.get("sn"), rec.get("so"), pos)
        if not p["giver"]:
            return None
    spots = objective_spots(rec)
    if stage in ("A", "C"):
        if rec.get("o") and not spots:
            return None
        p["spots"] = spots
    ref = pos if stage == "T" else (spots[0] if spots else (p.get("giver") or pos))
    p["finisher"] = nearest(W, rec.get("en"), rec.get("eo"), ref)
    if not p["finisher"]:
        return None
    level = max(snap.get("level") or 1, p["rl"] if locked else 0)
    v, _ = value(p, level, wt)
    if v <= 0 and stage == "A":
        return None
    return p


def collect(W: World, state: StateFn, snap: dict[str, Any], wt: dict[str, Any], wide: bool):
    pool = []
    seen: set[int] = set()
    for m in zones(W, snap, wt, wide):
        for q in W.zone_quests(m):
            if q in seen or (snap.get("skipped") or {}).get(q):
                continue
            seen.add(q)
            rec = W.quest(q)
            st, reason = state(q)
            stage, locked = stage_of(st, reason, rec or {})
            if rec and stage:
                p = packet(W, q, rec, stage, locked, snap, wt)
                if p:
                    pool.append(p)
    pool.sort(key=lambda p: p["q"])
    return pool


def candidates(W: World, state: StateFn, snap: dict[str, Any], wt: dict[str, Any]):
    pool = collect(W, state, snap, wt, False)
    if len(pool) < wt["localMin"]:
        pool = collect(W, state, snap, wt, True)
    return pool


# ---- sequence ------------------------------------------------------------------------------------


def between(
    a: dict[str, Any], b: dict[str, Any], wt: dict[str, Any], pathf
) -> tuple[float | None, Any]:
    if a["m"] == b["m"]:
        return dist(a["x"], a["y"], b["x"], b["y"]) * wt["speed"], None
    cost, edge = pathf(a["m"], b["m"])
    if cost is None:
        return None, None
    return cost, edge


def _leg(a, b, wt, pathf) -> float:
    c, _ = between(a, b, wt, pathf)
    return wt["unreachable"] if c is None else c


def spots_time(p: dict[str, Any], wt: dict[str, Any], pathf) -> float:
    spots = p.get("spots") or []
    t = len(spots) * wt["objective"] * (wt["eliteObjective"] if p["elite"] else 1)
    for i in range(1, len(spots)):
        t = t + _leg(spots[i - 1], spots[i], wt, pathf)
    return t


def task_of(p: dict[str, Any], st: str, wt: dict[str, Any], pathf) -> dict[str, Any]:
    if st == "A":
        g = p["giver"]
        return {
            "kind": "A",
            "m": g["m"],
            "x": g["x"],
            "y": g["y"],
            "id": g["id"],
            "idKind": g["kind"],
            "time": wt["accept"],
        }
    if st == "C":
        s = p["spots"][0]
        return {
            "kind": "C",
            "m": s["m"],
            "x": s["x"],
            "y": s["y"],
            "time": spots_time(p, wt, pathf),
        }
    f = p["finisher"]
    return {
        "kind": "T",
        "m": f["m"],
        "x": f["x"],
        "y": f["y"],
        "id": f["id"],
        "idKind": f["kind"],
        "time": wt["turnin"],
    }


def rest_of(p: dict[str, Any], st: str, wt: dict[str, Any], pathf) -> float:
    f = p["finisher"]
    if st == "T":
        return 0
    spots = p.get("spots") or []
    if st == "C":
        return _leg(spots[-1], f, wt, pathf) + wt["turnin"]
    if not spots:
        return _leg(p["giver"], f, wt, pathf) + wt["turnin"]
    return (
        _leg(p["giver"], spots[0], wt, pathf)
        + spots_time(p, wt, pathf)
        + _leg(spots[-1], f, wt, pathf)
        + wt["turnin"]
    )


def next_stage(p: dict[str, Any], st: str) -> str:
    if st == "A":
        return "C" if p.get("spots") else "T"
    if st == "C":
        return "T"
    return "done"


def unlocked(p: dict[str, Any], sim: dict[str, Any], is_done: Callable[[int], bool]) -> bool:
    if sim["level"] < (p.get("rl") or 1):
        return False

    def done(q: int) -> bool:
        return bool(sim["done"].get(q)) or is_done(q)

    for q in p.get("pa") or []:
        if not done(q):
            return False
    po = p.get("po") or []
    if po:
        return any(done(q) for q in po)
    return True


def _better(a: dict[str, Any], b: dict[str, Any] | None) -> bool:
    if b is None:
        return True
    if abs(a["score"] - b["score"]) > 1e-9 * max(1, abs(b["score"])):
        return a["score"] > b["score"]
    if abs(a["travel"] - b["travel"]) > 1e-9:
        return a["travel"] < b["travel"]
    if a["task"]["kind"] != b["task"]["kind"]:
        return KIND_ORDER[a["task"]["kind"]] < KIND_ORDER[b["task"]["kind"]]
    return a["p"]["q"] < b["p"]["q"]


def prepare(pool, wt, pathf):
    cache = []
    for p in pool:
        c: dict[str, Any] = {"task": {}, "rest": {}, "value": {}}
        for st in ("A", "C", "T"):
            ok = (st == "A" and p.get("giver")) or (st == "C" and p.get("spots")) or st == "T"
            if ok:
                c["task"][st] = task_of(p, st, wt, pathf)
                c["rest"][st] = rest_of(p, st, wt, pathf)
        cache.append(c)
    return cache


def best_task(pool, stages, sim, wt, pathf, is_done, cache, indices=None):
    opened = []
    nearest_c = None
    for i in indices if indices is not None else range(len(pool)):
        p = pool[i]
        st = stages[i]
        if st != "done" and (not p["locked"] or sim["open"].get(i) or unlocked(p, sim, is_done)):
            task = cache[i]["task"][st]
            opened.append((i, p, st, task))
            if st == "C" and task["m"] == sim["m"]:
                d = dist(sim["x"], sim["y"], task["x"], task["y"])
                if nearest_c is None or d < nearest_c:
                    nearest_c = d
    best = best_here = None
    for i, p, st, task in opened:
        d = dist(sim["x"], sim["y"], task["x"], task["y"]) if task["m"] == sim["m"] else None
        here = d is not None and d <= wt["here"] and st != "C"
        deferred = st == "T" and not here and nearest_c is not None and (d is None or nearest_c < d)
        if deferred:
            continue
        travel, edge = between(sim, task, wt, pathf)
        if travel is None:
            continue
        if sim["level"] not in cache[i]["value"]:
            cache[i]["value"][sim["level"]] = value(p, sim["level"], wt)
        v, terms = cache[i]["value"][sim["level"]]
        ob = obligation(st, wt)
        if v <= 0:
            continue
        rest = cache[i]["rest"][st]
        cost = max(travel + task["time"] + rest, wt["minCost"])
        score = v * ob / cost
        leave = near = False
        if task["m"] != sim["m"]:
            score = score / wt["leaveZone"]
            leave = True
        elif dist(sim["x"], sim["y"], task["x"], task["y"]) <= wt["near"]:
            score = score * wt["nearBonus"]
            near = True
        c = {
            "i": i,
            "p": p,
            "task": task,
            "travel": travel,
            "edge": edge,
            "score": score,
            "why": {
                "value": v,
                "obligation": ob,
                "travel": travel,
                "time": task["time"],
                "rest": rest,
                "cost": cost,
                "leave": leave,
                "near": near,
                "here": here,
                "xp": terms["xp"],
                "colour": terms["colour"],
                "score": score,
            },
        }
        if here:
            if _better(c, best_here):
                best_here = c
        elif _better(c, best):
            best = c
    return best_here or best


def _level_up(sim: dict[str, Any], level_xp: list[int]) -> None:
    while (
        sim["level"] < 60
        and sim["level"] <= len(level_xp)
        and sim["xp"] >= level_xp[sim["level"] - 1]
    ):
        sim["xp"] = sim["xp"] - level_xp[sim["level"] - 1]
        sim["level"] = sim["level"] + 1


def run(pool, snap, wt, pathf, is_done=None, first=None, level_xp=None):
    is_done = is_done or (lambda q: False)
    if level_xp is None:
        _, level_xp = load_weights()
    sim = {
        "m": snap.get("mapID"),
        "x": snap.get("x") or 50,
        "y": snap.get("y") or 50,
        "level": snap.get("level") or 1,
        "xp": snap.get("xp") or 0,
        "done": {},
        "open": {},
    }
    stages = [p["stage"] for p in pool]
    cache = prepare(pool, wt, pathf)
    steps: list[dict[str, Any]] = []
    while len(steps) < wt["lookahead"]:
        best = None
        if first is not None:
            for i, p in enumerate(pool):
                if p["q"] == first and stages[i] != "done":
                    best = best_task(pool, stages, sim, wt, pathf, is_done, cache, [i]) or best
            first = None
        best = best or best_task(pool, stages, sim, wt, pathf, is_done, cache)
        if not best:
            break
        p, task = best["p"], best["task"]
        if task["m"] != sim["m"]:
            e = best["edge"] or {}
            has_x = e.get("x") is not None
            steps.append(
                {
                    "t": "V",
                    "k": f"plan:V:{task['m']}:{p['q']}",
                    "z": sim["m"] if has_x else task["m"],
                    "x": e["x"] if has_x else task["x"],
                    "y": e["y"] if has_x else task["y"],
                    "to": task["m"],
                    "via": e.get("via") or "walk",
                    "q": p["q"],
                    "el": sim["level"],
                }
            )
            if len(steps) >= wt["lookahead"]:
                break
        step = {
            "t": task["kind"],
            "k": f"plan:{task['kind']}:{p['q']}",
            "q": p["q"],
            "n": p["n"],
            "z": task["m"],
            "x": task["x"],
            "y": task["y"],
            "el": sim["level"],
            "score": best["score"],
            "why": best["why"],
        }
        steps.append(step)
        sim["m"], sim["x"], sim["y"] = task["m"], task["x"], task["y"]
        if p["locked"]:
            sim["open"][best["i"]] = True
        stages[best["i"]] = next_stage(p, stages[best["i"]])
        if stages[best["i"]] == "done":
            sim["done"][p["q"]] = True
            sim["xp"] = sim["xp"] + xp_at(
                p["xp"] or 0, p["lv"] if p["lv"] is not None else sim["level"], sim["level"]
            )
            _level_up(sim, level_xp)
    return improve(steps, snap, wt, pathf)


def improve(steps, snap, wt, pathf):
    start = {"m": snap.get("mapID"), "x": snap.get("x") or 50, "y": snap.get("y") or 50}

    def pt(i: int) -> dict[str, Any]:
        if i < 0:
            return start
        s = steps[i]
        return {"m": s["z"], "x": s["x"], "y": s["y"]}

    for _ in range(wt["improvePasses"]):
        changed = False
        for i in range(len(steps) - 1):
            a, b = steps[i], steps[i + 1]
            movable = (
                a["t"] != "V"
                and b["t"] != "V"
                and a["q"] != b["q"]
                and a["z"] == b["z"]
                and not (a["t"] == "T" and b["t"] == "A")
            )
            if not movable:
                continue
            prev = pt(i - 1)
            nxt = pt(i + 2) if i + 2 < len(steps) else None
            pa, pb = pt(i), pt(i + 1)
            now = (
                _leg(prev, pa, wt, pathf)
                + _leg(pa, pb, wt, pathf)
                + (_leg(pb, nxt, wt, pathf) if nxt else 0)
            )
            swapped = (
                _leg(prev, pb, wt, pathf)
                + _leg(pb, pa, wt, pathf)
                + (_leg(pa, nxt, wt, pathf) if nxt else 0)
            )
            if swapped < now - 1e-9:
                steps[i], steps[i + 1] = b, a
                changed = True
        if not changed:
            break
    return steps


def build(
    W: World,
    state: StateFn,
    snap: dict[str, Any],
    wt: dict[str, Any],
    first: int | None = None,
    level_xp: list[int] | None = None,
):
    """A plan: the list of steps (``k``, ``t``, ``q``, ``z``, ``x``, ``y`` ...)."""
    pool = candidates(W, state, snap, wt)
    pathf = path_cache(W.travel, wt)

    def is_done(q: int) -> bool:
        return state(q)[0] == "completed"

    return run(pool, snap, wt, pathf, is_done, first, level_xp)


def weights_for(overrides: dict[str, Any] | None = None) -> tuple[dict[str, Any], list[int]]:
    default, level_xp = load_weights()
    wt = copy.deepcopy(default)
    if overrides:
        merge(wt, overrides)
    return wt, level_xp
