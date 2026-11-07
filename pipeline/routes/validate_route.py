"""Route validator: the hard gate between LLM output and the compiler (PRD 6.6).

Every error blocks the build; warnings are reported and never block. Messages say what to
change, because the usual reader is an agent fixing its own route.

Steps are numbered from 1 in all output (the same position the add-on uses at runtime).
"""

from __future__ import annotations

import json
import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

from pipeline.routes.world import World, distance, level_at_xp, xp_budget
from pipeline.shape.factions import CLASS_BITS

SCHEMA_PATH = Path(__file__).with_name("schema.json")
CURATED_SCHEMA_PATH = Path(__file__).with_name("curated.schema.json")

# ---- thresholds (all in map-percent unless noted) -----------------------------------------
COORD_TOLERANCE = 3.0  # ACCEPT/TURNIN may be this far from a DB spawn (PRD 6.6)
HUB_RADIUS = 8.0  # a step within this distance of a known hub counts as "at the hub"
FM_RADIUS = 5.0  # a step this close to a flight master "passes" it
EXCURSION_LIMIT = 45.0  # distance from the last hub before an excursion needs a way home
XP_LOW, XP_HIGH = 1.00, 1.40  # accepted XP / budget range (PRD 6.6)
TRAINER_GAP = 3  # levels between trainer visits before a warning
MOB_LEVEL_MARGIN = 3  # objective mob this many levels above the expected level -> warning
ROUND_TRIPS = 2  # more than this many hub round-trips in a row -> warning

QUEST_STEPS = {"ACCEPT", "COMPLETE", "TURNIN"}
TAGS_FOR_XP = {"main", "optional"}

ERROR = "error"
WARNING = "warning"


@dataclass
class Issue:
    severity: str
    code: str
    message: str
    step: int | None = None  # 1-based; None = route level
    step_label: str = ""
    reviewed: str | None = None

    def as_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "severity": self.severity,
            "code": self.code,
            "step": self.step,
            "message": self.message,
        }
        if self.step_label:
            out["stepLabel"] = self.step_label
        if self.reviewed is not None:
            out["reviewed"] = self.reviewed
        return out


@dataclass
class Report:
    route_id: str
    file: str = ""
    issues: list[Issue] = field(default_factory=list)
    stats: dict[str, Any] = field(default_factory=dict)

    @property
    def errors(self) -> list[Issue]:
        return [i for i in self.issues if i.severity == ERROR]

    @property
    def warnings(self) -> list[Issue]:
        return [i for i in self.issues if i.severity == WARNING]

    @property
    def ok(self) -> bool:
        return not self.errors


@dataclass
class PathState:
    """What the player has already done when this band starts (one stitched path)."""

    label: str
    accepted: set[int] = field(default_factory=set)
    turned_in: set[int] = field(default_factory=set)
    dropped: set[int] = field(default_factory=set)
    used: set[int] = field(default_factory=set)
    fps: list[tuple[int, float, float]] = field(default_factory=list)
    complete: bool = True  # False if the chain back to level 1 is not fully loaded
    # Races that can follow this chain (the start branch's races). Steps limited to other races
    # never happen on this path. None means unknown: every step counts.
    races: frozenset[str] | None = None


# ---- route store ---------------------------------------------------------------------------


def load_route_dir(directory: Path) -> dict[str, dict[str, Any]]:
    """All ``*.route.json`` in a folder, by id. A real route wins over a sample with its id."""
    routes: dict[str, dict[str, Any]] = {}
    for path in sorted(directory.glob("*.route.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        rid = data.get("id")
        if not isinstance(rid, str):
            continue
        if rid in routes and not routes[rid].get("sample") and data.get("sample"):
            continue
        routes[rid] = data
    return routes


def pack_id_of(route: dict[str, Any]) -> str:
    """Pack file stem for a route id: ``horde_durotar_01-05`` -> ``durotar_01-05``."""
    rid = str(route.get("id", ""))
    prefix = f"{route.get('faction', '')}_"
    return rid[len(prefix) :] if rid.startswith(prefix) else rid


def expected_id(route: dict[str, Any]) -> str | None:
    band = route.get("band")
    if not (isinstance(band, list) and len(band) == 2):
        return None
    rid = str(route.get("id", ""))
    suffix = rid[-1] if rid and rid[-1].isalpha() else ""
    return f"{route.get('faction')}_{route.get('branch')}_{band[0]:02d}-{band[1]:02d}{suffix}"


# ---- the validator -------------------------------------------------------------------------


class RouteValidator:
    def __init__(
        self,
        world: World,
        routes: dict[str, dict[str, Any]] | None = None,
        *,
        stitched: bool = False,
    ) -> None:
        self.world = world
        self.routes = routes or {}
        self.stitched = stitched
        self._schema = Draft202012Validator(json.loads(SCHEMA_PATH.read_text(encoding="utf-8")))
        self._hubs_cache: dict[str, list[tuple[int, float, float, str]]] = {}

    # ---- entry points ------------------------------------------------------------------

    def validate(self, route: dict[str, Any], file: str = "") -> Report:
        report = Report(route_id=str(route.get("id", "?")), file=file)
        self._schema_issues(route, report)
        if report.errors:
            return report  # semantic checks need a well-formed route
        self._header_checks(route, report)
        paths = self._paths_before(route)
        self._static_checks(route, report)
        self._path_checks(route, paths, report)
        self._stitch_checks(route, paths, report)
        private = self._warning_checks(route, report)
        self._apply_reviews(route, report)
        report.stats = self._stats(route, paths, private)
        report.issues.sort(key=lambda i: (0 if i.step is None else 1, i.step or 0, i.code))
        return report

    # ---- issue helpers -----------------------------------------------------------------

    @staticmethod
    def _label(steps: list[dict[str, Any]], index: int) -> str:
        step = steps[index]
        label = str(step["type"])
        if "quest" in step:
            label += f" {step['quest']}"
        return label

    def _add(
        self,
        report: Report,
        severity: str,
        code: str,
        message: str,
        route: dict[str, Any] | None = None,
        index: int | None = None,
    ) -> None:
        step_no = None if index is None else index + 1
        label = "" if route is None or index is None else self._label(route["steps"], index)
        report.issues.append(Issue(severity, code, message, step_no, label))

    # ---- schema ------------------------------------------------------------------------

    def _schema_issues(self, route: dict[str, Any], report: Report) -> None:
        errors = sorted(self._schema.iter_errors(route), key=lambda e: list(map(str, e.path)))
        for error in errors:
            path = list(error.absolute_path)
            index = path[1] if len(path) >= 2 and path[0] == "steps" else None
            where = "/".join(str(p) for p in path) or "(root)"
            message = f"schema: {error.message} [at {where}]"
            if error.validator == "not" and isinstance(error.instance, dict):
                extra = sorted(set(error.instance) & {"quest", "tag", "objectiveIndex"})
                message = (
                    f"schema: a {error.instance.get('type')} step must not have {extra}; "
                    f"only ACCEPT/COMPLETE/TURNIN use them [at {where}]"
                )
            steps = route.get("steps") if isinstance(route.get("steps"), list) else None
            label = ""
            if isinstance(index, int) and steps is not None and index < len(steps):
                step = steps[index]
                if isinstance(step, dict):
                    label = str(step.get("type", ""))
                    if "quest" in step:
                        label += f" {step['quest']}"
            report.issues.append(
                Issue(ERROR, "E_SCHEMA", message, None if index is None else index + 1, label)
            )

    # ---- header ------------------------------------------------------------------------

    def _header_checks(self, route: dict[str, Any], report: Report) -> None:
        world = self.world
        lo, hi = route["band"]
        if hi <= lo:
            self._add(report, ERROR, "E_BAND", f"band {route['band']}: hi must be greater than lo.")
        want = expected_id(route)
        if want and route["id"] != want:
            self._add(
                report,
                ERROR,
                "E_ID",
                f"id '{route['id']}' does not match faction/branch/band; "
                f"expected '{want}' (a trailing part letter such as 'a' is allowed).",
            )
        if route["faction"] != world.faction.id:
            self._add(
                report,
                ERROR,
                "E_FACTION",
                f"faction '{route['faction']}' but the loaded data is '{world.faction.id}'.",
            )
        else:
            branches = {b.id for b in world.faction.branches} | {world.faction.shared_track}
            if route["branch"] not in branches:
                self._add(
                    report,
                    ERROR,
                    "E_BRANCH",
                    f"unknown branch '{route['branch']}'; use one of {sorted(branches)}.",
                )
        for key in ("entry", "exitPoint"):
            place = route[key]
            if world.zone_id(place["zone"]) is None:
                self._add(
                    report,
                    ERROR,
                    "E_UNKNOWN_ZONE",
                    f"{key}.zone '{place['zone']}' is not a known zone; "
                    "use a name from data/horde/travel.json 'zones'.",
                )
        stamp = world.db_stamp()
        if stamp["buildCommit"] and route["db"].get("buildCommit") != stamp["buildCommit"]:
            self._add(
                report,
                WARNING,
                "W_DB_STAMP",
                f"db.buildCommit {route['db'].get('buildCommit')!r} differs from the extract "
                f"({stamp['buildCommit'][:12]}...); set db to the manifest values "
                "after a DB refresh.",
            )

    # ---- stitched paths ----------------------------------------------------------------

    def _direct_predecessors(self, route: dict[str, Any]) -> list[dict[str, Any]]:
        shared = self.world.faction.shared_track
        out = []
        for other in self.routes.values():
            if other.get("next") != route["id"] or other["id"] == route["id"]:
                continue
            # Branch awareness: a race branch only follows its own branch. The shared track
            # follows every branch that points at it.
            if route["branch"] != shared and other["branch"] != route["branch"]:
                continue
            out.append(other)
        return sorted(out, key=lambda r: r["id"])

    def _chains_before(self, route: dict[str, Any]) -> list[list[dict[str, Any]]]:
        """All oldest-to-newest chains of routes that lead into ``route`` (excluded)."""
        chains: list[list[dict[str, Any]]] = []

        def walk(current: dict[str, Any], tail: list[dict[str, Any]], seen: frozenset[str]) -> None:
            preds = [p for p in self._direct_predecessors(current) if p["id"] not in seen]
            if not preds:
                chains.append(tail)
                return
            for pred in preds:
                walk(pred, [pred, *tail], seen | {pred["id"]})

        walk(route, [], frozenset({route["id"]}))
        return chains[:16]

    def _paths_before(self, route: dict[str, Any]) -> list[PathState]:
        states: list[PathState] = []
        for chain in self._chains_before(route):
            state = PathState(label=" > ".join(r["id"] for r in chain) or "(start)")
            state.complete = (chain[0]["band"][0] if chain else route["band"][0]) <= 1
            state.races = self._chain_races(chain[0] if chain else route)
            for prior in chain:
                for step in prior["steps"]:
                    if not self._step_on_path(step, state):
                        continue
                    quest = step.get("quest")
                    if step["type"] == "ACCEPT":
                        state.accepted.add(quest)
                    elif step["type"] == "TURNIN":
                        state.turned_in.add(quest)
                    elif step["type"] == "FP_DISCOVER":
                        zone = self.world.zone_id(step["zone"])
                        if zone is not None:
                            state.fps.append((zone, step["x"], step["y"]))
                    if quest:
                        state.used.add(quest)
                for dropped in prior["dropped"]:
                    state.dropped.add(dropped["quest"])
            states.append(state)
        return states

    def _chain_races(self, first: dict[str, Any]) -> frozenset[str] | None:
        """Races that follow a chain, from the start branch of its oldest route."""
        try:
            return frozenset(self.world.faction.branch(first["branch"]).races)
        except KeyError:
            return None  # the shared track or an unknown branch: every race

    @staticmethod
    def _step_on_path(step: dict[str, Any], state: PathState) -> bool:
        """False for a step limited to races that never take this path."""
        races = step.get("races")
        if not races or state.races is None:
            return True
        return bool(state.races & set(races))

    # ---- hubs and zones ----------------------------------------------------------------

    def _hubs(self, route: dict[str, Any]) -> list[tuple[int, float, float, str]]:
        key = pack_id_of(route)
        if key in self._hubs_cache:
            return self._hubs_cache[key]
        world = self.world
        hubs: list[tuple[int, float, float, str]] = []
        pack = world.pack(key)
        for hub in (pack or {}).get("hubs", []):
            hubs.append((hub["z"], hub["x"], hub["y"], hub["name"]))
        for place in world.travel.get("manual", {}).get("settlements", []):
            zone = world.zone_id(place["zone"])
            if zone is not None:
                hubs.append((zone, place["x"], place["y"], place["name"]))
        for inn in world.travel.get("innkeepers", []):
            hubs.append((inn["zone"], inn["x"], inn["y"], inn["place"]))
        self._hubs_cache[key] = hubs
        return hubs

    def _hub_of(
        self, route: dict[str, Any], zone: int, x: float, y: float
    ) -> tuple[str, float] | None:
        best: tuple[str, float, tuple[bool, float]] | None = None
        for hub_zone, hx, hy, name in self._hubs(route):
            if hub_zone != zone:
                continue
            d = distance(x, y, hx, hy)
            if d > HUB_RADIUS:
                continue
            # a generated name like "Zephra's Isle (44, 45)" loses to a real settlement name
            rank = (bool(re.search(r"\(\d", name)), d)
            if best is None or rank < best[2]:
                best = (name, d, rank)
        return (best[0], best[1]) if best else None

    def _step_place(self, step: dict[str, Any]) -> tuple[int, float, float] | None:
        if "x" not in step:
            return None
        zone = self.world.zone_id(step["zone"])
        return None if zone is None else (zone, step["x"], step["y"])

    # ---- static checks (independent of the path) ---------------------------------------

    def _static_checks(self, route: dict[str, Any], report: Report) -> None:
        world = self.world
        steps = route["steps"]
        for index, step in enumerate(steps):
            if "zone" in step and world.zone_id(step["zone"]) is None:
                self._add(
                    report,
                    ERROR,
                    "E_UNKNOWN_ZONE",
                    f"zone '{step['zone']}' is not a known zone; use a name from "
                    "data/horde/travel.json 'zones' (for example 'The Barrens').",
                    route,
                    index,
                )
            if "npc" in step and step["npc"] not in world.npcs:
                self._add(
                    report,
                    ERROR,
                    "E_UNKNOWN_NPC",
                    f"npc {step['npc']} does not exist in the DB; remove it or use a real NPC id.",
                    route,
                    index,
                )
            elif "npc" in step and step["type"] not in QUEST_STEPS:
                self._check_spawn_match(route, report, index, [("n", step["npc"])])
            if step["type"] in QUEST_STEPS:
                self._check_quest_step(route, report, index)
            elif step["type"] == "FP_DISCOVER":
                self._check_flight_master(route, report, index)
            elif step["type"] == "HEARTH_BIND":
                self._check_innkeeper(route, report, index)
        # dropped[]
        seen: set[int] = set()
        used = {s["quest"] for s in steps if "quest" in s}
        pack = world.pack(pack_id_of(route))
        elite = {
            q["i"]
            for q in (pack or {}).get("quests", [])
            if "elite" in q.get("fl", []) and not world.unplaceable(q["i"])
        }
        for entry in route["dropped"]:
            qid = entry["quest"]
            if qid not in world.quests:
                self._add(
                    report,
                    ERROR,
                    "E_UNKNOWN_QUEST",
                    f"dropped[] quest {qid} is not in the DB; remove the entry.",
                )
            if qid in seen:
                self._add(
                    report, ERROR, "E_DUP_DROPPED", f"quest {qid} appears twice in dropped[]."
                )
            seen.add(qid)
            if qid in used:
                self._add(
                    report,
                    ERROR,
                    "E_DROPPED_AND_USED",
                    f"quest {qid} is both in dropped[] and used by a step; delete one of them.",
                )
            if qid in elite:
                self._add(
                    report,
                    ERROR,
                    "E_ELITE_DROPPED",
                    f"quest {qid} is flagged elite in the pack and elite quests are never dropped; "
                    "remove it from dropped[] and add it with tag 'optional-elite' "
                    "(and revisitAt).",
                )

    def _check_quest_step(self, route: dict[str, Any], report: Report, index: int) -> None:
        world = self.world
        step = route["steps"][index]
        qid = step["quest"]
        quest = world.quests.get(qid)
        if quest is None:
            self._add(
                report,
                ERROR,
                "E_UNKNOWN_QUEST",
                f"quest {qid} is not in the DB; use an id from the band pack. Never invent ids.",
                route,
                index,
            )
            return
        name = quest.get("name", "?")
        if quest.get("placeholder"):
            self._add(
                report,
                ERROR,
                "E_UNKNOWN_QUEST",
                f"quest {qid} is a placeholder row ('REUSE ME'); remove the step.",
                route,
                index,
            )
            return
        if "title" in step and step["title"] != name:
            self._add(
                report,
                WARNING,
                "W_TITLE",
                f"title '{step['title']}' differs from the DB name '{name}'.",
                route,
                index,
            )
        if not world.faction_available(quest):
            self._add(
                report,
                ERROR,
                "E_FACTION_QUEST",
                f"quest {qid} '{name}' is not available to {world.faction.id}; remove the step.",
                route,
                index,
            )
        self._check_class_race(route, report, index, quest)
        required = int(quest.get("requiredLevel") or 0)
        if "minLevel" in step and step["minLevel"] < required:
            self._add(
                report,
                ERROR,
                "E_MIN_LEVEL",
                f"minLevel {step['minLevel']} is below the quest's requiredLevel {required}; "
                f"set minLevel to at least {required}.",
                route,
                index,
            )
        if step["type"] == "ACCEPT" and required > route["band"][1]:
            self._add(
                report,
                WARNING,
                "W_REQUIRED_LEVEL",
                f"quest {qid} needs level {required}, above the band's top level "
                f"{route['band'][1]}; move it to a later band or add minLevel.",
                route,
                index,
            )
        if step["type"] == "COMPLETE" and "objectiveIndex" in step:
            count = self._objective_count(quest)
            if count and step["objectiveIndex"] > count:
                self._add(
                    report,
                    ERROR,
                    "E_OBJECTIVE_INDEX",
                    f"objectiveIndex {step['objectiveIndex']} but the quest has only {count} "
                    "objective(s) (1-based).",
                    route,
                    index,
                )
        if step["type"] in ("ACCEPT", "TURNIN"):
            role = "start" if step["type"] == "ACCEPT" else "finish"
            self._check_quest_giver(route, report, index, role)
        elif "x" not in step:
            self._add(
                report,
                WARNING,
                "W_NO_COORDS",
                "COMPLETE step has no zone/x/y; add the objective area so the arrow can guide.",
                route,
                index,
            )

    @staticmethod
    def _objective_count(quest: dict[str, Any]) -> int:
        count = 0
        for value in (quest.get("objectives") or {}).values():
            if isinstance(value, list):
                count += len(value)
        return count + len(quest.get("extraObjectives") or [])

    def _check_class_race(
        self, route: dict[str, Any], report: Report, index: int, quest: dict[str, Any]
    ) -> None:
        world = self.world
        step = route["steps"][index]
        qid = step["quest"]
        class_mask = int(quest.get("requiredClasses") or 0)
        step_classes = step.get("classes")
        if class_mask:
            allowed = sorted(c for c, bit in CLASS_BITS.items() if class_mask & bit)
            if not step_classes:
                self._add(
                    report,
                    ERROR,
                    "E_CLASS_QUEST",
                    f'quest {qid} is only for {allowed}; add "classes": {json.dumps(allowed)} '
                    "so other classes do not see it.",
                    route,
                    index,
                )
            else:
                bad = sorted(c for c in step_classes if c not in allowed)
                if bad:
                    self._add(
                        report,
                        ERROR,
                        "E_CLASS_QUEST",
                        f"quest {qid} is not available to {bad}; its classes are {allowed}.",
                        route,
                        index,
                    )
        race_mask = world.quest_races_mask(quest)
        branch = route["branch"]
        branch_mask = (
            world.faction.branch_race_mask(branch)
            if branch in {b.id for b in world.faction.branches}
            else world.faction.race_mask
        )
        step_races = step.get("races")
        if step_races:
            foreign = sorted(r for r in step_races if not world.race_bits(r))
            if foreign:
                self._add(
                    report,
                    ERROR,
                    "E_RACE_QUEST",
                    f"races {foreign} do not belong to {world.faction.id}; remove them.",
                    route,
                    index,
                )
            bad = sorted(
                r
                for r in step_races
                if world.race_bits(r) and race_mask and not race_mask & world.race_bits(r)
            )
            if bad:
                self._add(
                    report,
                    ERROR,
                    "E_RACE_QUEST",
                    f"quest {qid} is not available to {bad}; remove them from races.",
                    route,
                    index,
                )
            if branch_mask:
                outside = sorted(r for r in step_races if not branch_mask & world.race_bits(r))
                if outside and branch != world.faction.shared_track:
                    self._add(
                        report,
                        WARNING,
                        "W_RACE_BRANCH",
                        f"races {outside} are not part of branch '{branch}'; "
                        "the step is never shown.",
                        route,
                        index,
                    )
        elif race_mask and (branch_mask & ~race_mask):
            names = sorted(
                r
                for r in ("Orc", "Troll", "Tauren", "Undead", "Human", "Dwarf", "NightElf", "Gnome")
                if race_mask & world.race_bits(r)
            )
            self._add(
                report,
                ERROR,
                "E_RACE_QUEST",
                f"quest {qid} is limited to {names}, but branch '{branch}' also has other races; "
                f'add "races": {json.dumps(names)}.',
                route,
                index,
            )

    def _check_quest_giver(
        self, route: dict[str, Any], report: Report, index: int, role: str
    ) -> None:
        world = self.world
        step = route["steps"][index]
        qid = step["quest"]
        givers = world.quest_giver(qid, role)
        if "npc" in step:
            if ("n", step["npc"]) not in givers and ("o", step["npc"]) not in givers:
                self._add(
                    report,
                    ERROR,
                    "E_NPC_MISMATCH",
                    f"npc {step['npc']} does not {role} quest {qid}; the DB lists "
                    f"{[g[1] for g in givers]}. Remove npc or correct it.",
                    route,
                    index,
                )
                return
            givers = [g for g in givers if g[1] == step["npc"]]
        spawnable = [g for g in givers if g[0] in ("n", "o")]
        if not spawnable:
            return  # item starters and the like have no map position
        self._check_spawn_match(route, report, index, spawnable)

    def _check_spawn_match(
        self,
        route: dict[str, Any],
        report: Report,
        index: int,
        targets: list[tuple[str, int]],
    ) -> None:
        world = self.world
        step = route["steps"][index]
        zone = world.zone_id(step.get("zone", ""))
        if zone is None or "x" not in step:
            return
        spawns: list[tuple[int, float, float, str]] = []
        for kind, entity_id in targets:
            table = world.npcs if kind == "n" else world.objects
            label = f"{table.get(entity_id, {}).get('name', '?')} ({entity_id})"
            spawns.extend((z, x, y, label) for z, x, y in world.entity_spawns(kind, entity_id))
        if not spawns:
            return
        here = [s for s in spawns if s[0] == zone]
        if not here:
            where = sorted({f"{world.zone_name(s[0])} [{s[3]}]" for s in spawns})
            self._add(
                report,
                ERROR,
                "E_WRONG_ZONE",
                f"zone '{step['zone']}' is wrong: spawns are only in {', '.join(where)}. "
                "Set zone, x and y to one of those positions.",
                route,
                index,
            )
            return
        nearest = min(here, key=lambda s: distance(step["x"], step["y"], s[1], s[2]))
        gap = distance(step["x"], step["y"], nearest[1], nearest[2])
        if gap > COORD_TOLERANCE:
            self._add(
                report,
                ERROR,
                "E_COORDS",
                f"({step['x']}, {step['y']}) is {gap:.1f} map-% from the nearest spawn of "
                f"{nearest[3]} at ({nearest[1]}, {nearest[2]}) in {step['zone']} "
                f"(limit {COORD_TOLERANCE}); set x={nearest[1]}, y={nearest[2]}.",
                route,
                index,
            )

    def _check_flight_master(self, route: dict[str, Any], report: Report, index: int) -> None:
        world = self.world
        step = route["steps"][index]
        zone = world.zone_id(step["zone"])
        if zone is None:
            return
        masters = [f for f in world.travel.get("flightMasters", []) if f["zone"] == zone]
        near = [
            f for f in masters if distance(step["x"], step["y"], f["x"], f["y"]) <= COORD_TOLERANCE
        ]
        if near:
            return
        if masters:
            best = min(masters, key=lambda f: distance(step["x"], step["y"], f["x"], f["y"]))
            hint = f"nearest is {best['name']} at ({best['x']}, {best['y']})"
        else:
            hint = "travel.json lists no flight master in this zone"
        self._add(
            report,
            ERROR,
            "E_FP_LOCATION",
            f"no flight master within {COORD_TOLERANCE} map-% of ({step['x']}, {step['y']}) in "
            f"{step['zone']}; {hint}.",
            route,
            index,
        )

    def _check_innkeeper(self, route: dict[str, Any], report: Report, index: int) -> None:
        world = self.world
        step = route["steps"][index]
        zone = world.zone_id(step["zone"])
        if zone is None or "npc" in step:
            return
        inns = [i for i in world.travel.get("innkeepers", []) if i["zone"] == zone]
        if not any(distance(step["x"], step["y"], i["x"], i["y"]) <= COORD_TOLERANCE for i in inns):
            self._add(
                report,
                WARNING,
                "W_INNKEEPER",
                f"no known innkeeper within {COORD_TOLERANCE} map-% of ({step['x']}, {step['y']}) "
                f"in {step['zone']}; HEARTH_BIND must be at an inn (see travel.json 'innkeepers').",
                route,
                index,
            )

    # ---- path-dependent checks ---------------------------------------------------------

    def _path_checks(self, route: dict[str, Any], paths: list[PathState], report: Report) -> None:
        collected: dict[tuple[str, int | None, str, str], tuple[Issue, set[str]]] = {}
        for state in paths:
            for issue in self._walk_path(route, state):
                key = (issue.code, issue.step, issue.message, issue.severity)
                if key in collected:
                    collected[key][1].add(state.label)
                else:
                    collected[key] = (issue, {state.label})
        multi = len(paths) > 1
        for issue, labels in collected.values():
            if multi and len(labels) < len(paths):
                issue.message += f" [only when arriving via {' | '.join(sorted(labels))}]"
            report.issues.append(issue)

    def _walk_path(self, route: dict[str, Any], state: PathState) -> list[Issue]:
        world = self.world
        steps = route["steps"]
        out: list[Issue] = []

        def add(severity: str, code: str, message: str, index: int | None = None) -> None:
            step_no = None if index is None else index + 1
            label = "" if index is None else self._label(steps, index)
            out.append(Issue(severity, code, message, step_no, label))

        accepted_at: dict[int, int] = {}
        completed_at: dict[int, list[int]] = {}
        turnin_at: dict[int, int] = {}
        for i, step in enumerate(steps):
            q = step.get("quest")
            if step["type"] == "ACCEPT":
                accepted_at.setdefault(q, i)
            elif step["type"] == "TURNIN":
                turnin_at.setdefault(q, i)
            elif step["type"] == "COMPLETE":
                completed_at.setdefault(q, []).append(i)
        dropped_here = {d["quest"] for d in route["dropped"]}

        accepted = set(state.accepted)
        turned_in = set(state.turned_in)
        seen_complete: set[tuple[int, int | None]] = set()
        fps = list(state.fps)
        passed_fm: set[int] = set()
        for i, step in enumerate(steps):
            if not self._step_on_path(step, state):
                continue
            kind = step["type"]
            q = step.get("quest")
            quest = world.quests.get(q) if q else None
            if kind == "ACCEPT" and quest:
                if q in accepted:
                    where = (
                        "an earlier band" if q in state.accepted else f"step {accepted_at[q] + 1}"
                    )
                    add(
                        ERROR,
                        "E_DUPLICATE",
                        f"quest {q} was already accepted in {where}; remove this ACCEPT.",
                        i,
                    )
                else:
                    self._check_prereqs(add, i, q, quest, turned_in, turnin_at, dropped_here, state)
                    self._check_exclusive(add, i, q, quest, accepted, accepted_at, state)
                accepted.add(q)
            elif kind == "COMPLETE" and quest:
                key = (q, step.get("objectiveIndex"))
                if key in seen_complete:
                    add(
                        ERROR,
                        "E_DUPLICATE",
                        f"COMPLETE {q} repeated"
                        + (f" for objectiveIndex {key[1]}" if key[1] else "")
                        + "; remove the duplicate.",
                        i,
                    )
                seen_complete.add(key)
                if q not in accepted:
                    later = accepted_at.get(q)
                    hint = (
                        f"its ACCEPT is at step {later + 1}, after this step; "
                        "move COMPLETE below it"
                        if later is not None
                        else "add an ACCEPT step before it (or fix the quest id)"
                    )
                    add(
                        ERROR,
                        "E_COMPLETE_BEFORE_ACCEPT",
                        f"COMPLETE {q} without a prior ACCEPT: {hint}.",
                        i,
                    )
                if q in turned_in:
                    add(
                        ERROR,
                        "E_COMPLETE_AFTER_TURNIN",
                        f"COMPLETE {q} comes after the quest was turned in; "
                        "move it before the TURNIN.",
                        i,
                    )
            elif kind == "TURNIN" and quest:
                if q in turned_in:
                    where = (
                        "an earlier band" if q in state.turned_in else f"step {turnin_at[q] + 1}"
                    )
                    add(
                        ERROR,
                        "E_DUPLICATE",
                        f"quest {q} was already turned in at {where}; remove this TURNIN.",
                        i,
                    )
                if q not in accepted:
                    later = accepted_at.get(q)
                    hint = (
                        f"its ACCEPT is at step {later + 1}, after this TURNIN; move the ACCEPT up"
                        if later is not None
                        else "add an ACCEPT step before it, or accepted it in the previous band"
                    )
                    add(
                        ERROR,
                        "E_TURNIN_BEFORE_ACCEPT",
                        f"TURNIN {q} without a prior ACCEPT: {hint}.",
                        i,
                    )
                pending = [c for c in completed_at.get(q, []) if c > i]
                if pending:
                    add(
                        ERROR,
                        "E_TURNIN_BEFORE_COMPLETE",
                        f"TURNIN {q} is before its COMPLETE at step {pending[0] + 1}; "
                        "move the TURNIN after the COMPLETE steps.",
                        i,
                    )
                turned_in.add(q)
            elif kind == "FP_DISCOVER":
                zone = world.zone_id(step["zone"])
                if zone is not None:
                    fps.append((zone, step["x"], step["y"]))
            # flight masters passed before being discovered
            if kind not in ("FP_DISCOVER", "FLY"):
                place = self._step_place(step)
                if place:
                    for fm in world.travel.get("flightMasters", []):
                        if fm["zone"] != place[0] or fm["id"] in passed_fm:
                            continue
                        if distance(place[1], place[2], fm["x"], fm["y"]) > FM_RADIUS:
                            continue
                        known = any(
                            z == fm["zone"] and distance(x, y, fm["x"], fm["y"]) <= FM_RADIUS
                            for z, x, y in fps
                        )
                        if not known and not any(
                            s["type"] == "FP_DISCOVER"
                            and s.get("zone") == step.get("zone")
                            and distance(s["x"], s["y"], fm["x"], fm["y"]) <= FM_RADIUS
                            for s in steps[i + 1 :]
                        ):
                            passed_fm.add(fm["id"])
                            add(
                                WARNING,
                                "W_FP_MISSED",
                                f"passes flight master {fm['name']} ({fm['nodeName']}) at "
                                f"({fm['x']}, {fm['y']}) without an FP_DISCOVER step; add one "
                                "here or earlier.",
                                i,
                            )
        # open quests at the end of the band
        nxt = self.routes.get(route.get("next") or "")
        later_turnins = {
            s.get("quest") for s in (nxt or {}).get("steps", []) if s["type"] == "TURNIN"
        }
        for q in sorted(accepted - turned_in - state.accepted):
            if q not in later_turnins:
                add(
                    WARNING,
                    "W_OPEN_QUEST",
                    f"quest {q} '{world.quest_name(q)}' is accepted but not turned in by the "
                    "end of "
                    "the band" + ("" if nxt else " (next band not loaded)") + "; add the TURNIN, "
                    "or make sure the next band turns it in.",
                )
        # coverage of the pack
        out.extend(self._coverage(route, state, accepted_at))
        if not state.complete:
            out.append(
                Issue(
                    WARNING,
                    "W_PATH_INCOMPLETE",
                    "the chain of previous bands is not fully loaded; prerequisite and "
                    f"exclusive checks only cover {state.label}.",
                )
            )
        return out

    def _check_prereqs(
        self,
        add: Any,
        index: int,
        qid: int,
        quest: dict[str, Any],
        turned_in: set[int],
        turnin_at: dict[int, int],
        dropped_here: set[int],
        state: PathState,
    ) -> None:
        world = self.world
        group = [int(g) for g in quest.get("preQuestGroup") or []]
        # Data bug in QuestieDB: race/faction variants (1516, 1519, 92466) list themselves and
        # their exclusive siblings as "any one of" prerequisites. A quest can never require
        # itself or something it excludes, so those ids are ignored.
        unusable = {qid, *(int(e) for e in quest.get("exclusiveTo") or [])}
        single = [int(s) for s in quest.get("preQuestSingle") or [] if int(s) not in unusable]

        def why(pre: int) -> str:
            name = world.quest_name(pre)
            if pre in dropped_here or pre in state.dropped:
                return f"{pre} '{name}' is in dropped[]"
            if pre in turnin_at:
                return f"{pre} '{name}' is turned in only at step {turnin_at[pre] + 1}, later"
            q = world.quests.get(pre)
            if q is not None and not world.faction_available(q):
                return f"{pre} '{name}' is not available to {world.faction.id}"
            return f"{pre} '{name}' is not turned in earlier in the path"

        missing_all = [g for g in group if g not in turned_in]
        sev, code = (ERROR, "E_PREREQ") if state.complete else (WARNING, "W_PREREQ_UNVERIFIED")
        if missing_all:
            add(
                sev,
                code,
                f"ACCEPT {qid} needs all of {group} turned in first; missing: "
                + "; ".join(why(g) for g in missing_all)
                + ". Add the TURNIN earlier (and its ACCEPT), or remove this quest.",
                index,
            )
        if single and not any(s in turned_in for s in single):
            add(
                sev,
                code,
                f"ACCEPT {qid} needs one of {single} turned in first; "
                + "; ".join(why(s) for s in single)
                + ". Add one of them earlier, or remove this quest.",
                index,
            )

    def _check_exclusive(
        self,
        add: Any,
        index: int,
        qid: int,
        quest: dict[str, Any],
        accepted: set[int],
        accepted_at: dict[int, int],
        state: PathState,
    ) -> None:
        world = self.world
        mine = {int(e) for e in quest.get("exclusiveTo") or []}
        for other in sorted(accepted):
            theirs = {int(e) for e in (world.quests.get(other, {}).get("exclusiveTo") or [])}
            if other in mine or qid in theirs:
                where = (
                    "an earlier band"
                    if other in state.accepted
                    else f"step {accepted_at[other] + 1}"
                )
                add(
                    ERROR,
                    "E_EXCLUSIVE",
                    f"quest {qid} '{world.quest_name(qid)}' excludes {other} "
                    f"'{world.quest_name(other)}', which is already accepted at {where}. "
                    "Keep one of them and move the other to dropped[].",
                    index,
                )

    def _coverage(
        self, route: dict[str, Any], state: PathState, accepted_at: dict[int, int]
    ) -> list[Issue]:
        world = self.world
        out: list[Issue] = []
        pack = world.pack(pack_id_of(route))
        if pack is None:
            out.append(
                Issue(
                    WARNING,
                    "W_NO_PACK",
                    f"no band pack '{pack_id_of(route)}' found; cannot check that every "
                    "input quest is used or dropped.",
                )
            )
            return out
        in_pack = {q["i"] for q in pack["quests"]}
        used = {s["quest"] for s in route["steps"] if "quest" in s}
        dropped = {d["quest"] for d in route["dropped"]}
        missing = sorted(in_pack - used - dropped - state.used - state.dropped)
        if missing:
            names = {q["i"]: q["n"] for q in pack["quests"]}
            shown = ", ".join(f"{q} '{names[q]}'" for q in missing[:25])
            more = f" (+{len(missing) - 25} more)" if len(missing) > 25 else ""
            severity = WARNING if route.get("sample") else ERROR
            out.append(
                Issue(
                    severity,
                    "E_UNACCOUNTED" if severity == ERROR else "W_UNACCOUNTED",
                    f"{len(missing)} pack quest(s) are neither used by a step nor in "
                    f"dropped[]: {shown}{more}. Add a step or a dropped[] entry with a reason.",
                )
            )
        outside = sorted(q for q in used - in_pack if q in world.quests)
        if outside:
            out.append(
                Issue(
                    WARNING,
                    "W_NOT_IN_PACK",
                    f"quest(s) {outside[:15]} are not in the band pack '{pack_id_of(route)}'; "
                    "they exist in the DB but were not offered for this band.",
                )
            )
        return out

    # ---- stitching checks --------------------------------------------------------------

    def _stitch_checks(self, route: dict[str, Any], paths: list[PathState], report: Report) -> None:
        world = self.world
        preds = self._direct_predecessors(route)
        entry = route["entry"]
        for pred in preds:
            exit_point = pred["exitPoint"]
            problems = []
            if world.zone_id(entry["zone"]) != world.zone_id(exit_point["zone"]):
                problems.append(f"zone '{entry['zone']}' vs exitPoint zone '{exit_point['zone']}'")
            if entry.get("hub") and exit_point.get("hub") and entry["hub"] != exit_point["hub"]:
                problems.append(f"hub '{entry['hub']}' vs '{exit_point['hub']}'")
            if abs(entry["level"] - exit_point["level"]) > 1:
                problems.append(f"level {entry['level']} vs {exit_point['level']} (max 1 apart)")
            if problems:
                self._add(
                    report,
                    ERROR,
                    "E_ENTRY_MISMATCH",
                    f"entry does not match the exitPoint of {pred['id']}: "
                    + "; ".join(problems)
                    + ". Make them the same place (zone/hub) and within 1 level.",
                )
        if not preds and route["band"][0] > 1 and not route.get("sample"):
            self._add(
                report,
                ERROR if self.stitched else WARNING,
                "E_STITCH_ORPHAN" if self.stitched else "W_NO_PREDECESSOR",
                f"no loaded route has next == '{route['id']}', so the entry cannot be checked; "
                "generate or point the previous band's `next` here.",
            )
        nxt = route.get("next")
        if nxt:
            target = self.routes.get(nxt)
            if target is None:
                self._add(
                    report,
                    ERROR if self.stitched else WARNING,
                    "E_STITCH_NEXT_MISSING" if self.stitched else "W_NEXT_NOT_LOADED",
                    f"next '{nxt}' is not among the loaded routes.",
                )
            elif self.stitched:
                self._stitch_next(route, target, report)
        elif self.stitched and route["band"][1] < world.faction.levels[1]:
            self._add(
                report,
                ERROR,
                "E_STITCH_NO_NEXT",
                f"route ends at level {route['band'][1]} with no `next`; set next to the "
                "following band's id.",
            )

    def _stitch_next(self, route: dict[str, Any], target: dict[str, Any], report: Report) -> None:
        shared = self.world.faction.shared_track
        contiguous = target["band"][0] == route["band"][1]
        next_part = target["band"] == route["band"] and target["id"] != route["id"]
        if not (contiguous or next_part):
            self._add(
                report,
                ERROR,
                "E_STITCH_BAND_GAP",
                f"next {target['id']} starts at level {target['band'][0]} but this band ends at "
                f"{route['band'][1]}; the next band must start at {route['band'][1]} "
                "(or be the next part of the same band).",
            )
        if target["branch"] not in (route["branch"], shared):
            self._add(
                report,
                ERROR,
                "E_STITCH_BRANCH",
                f"next {target['id']} is branch '{target['branch']}'; a '{route['branch']}' "
                f"route can only continue into the same branch or '{shared}'.",
            )
        if target["id"] == route["id"] or self._reaches(target["id"], route["id"]):
            self._add(
                report, ERROR, "E_STITCH_CYCLE", f"next '{target['id']}' leads back here (cycle)."
            )

    def _reaches(self, start: str, goal: str) -> bool:
        seen: set[str] = set()
        current: str | None = start
        while current and current not in seen:
            if current == goal:
                return True
            seen.add(current)
            current = (self.routes.get(current) or {}).get("next")
        return False

    # ---- warnings from the walk through the whole route --------------------------------

    def _expected_levels(self, route: dict[str, Any]) -> tuple[list[float], dict[str, Any]]:
        """Expected player level at each step, assuming the band is paced to end at its top level.

        The cumulative quest XP at each step is scaled so that the whole route earns exactly the
        band's XP budget; kills and exploration are not modelled separately.
        """
        world = self.world
        lo, hi = route["band"]
        budget = xp_budget(lo, hi)
        gained: list[int] = []
        steps_count = len(route["steps"])
        counted: set[int] = set()
        missing: list[int] = []
        by_tag: Counter[str] = Counter()
        for step in route["steps"]:
            xp = 0
            if (
                step["type"] == "TURNIN"
                and step["quest"] not in counted
                and not step.get("classes")
            ):
                counted.add(step["quest"])
                value = world.quest_xp(step["quest"])
                if value is None:
                    missing.append(step["quest"])
                elif step["tag"] in TAGS_FOR_XP:
                    xp = value
                    by_tag[step["tag"]] += value
            gained.append(xp)
        total = sum(gained)
        levels: list[float] = []
        running = 0
        for xp in gained:
            running += xp
            levels.append(level_at_xp(lo, budget * running / total) if total else float(lo))
        known = bool(total)
        if not known and steps_count:
            # No XP data at all (e.g. Forever-only quests): spread the band evenly over the steps.
            levels = [lo + (hi - lo) * (i + 1) / steps_count for i in range(steps_count)]
        info = {
            "known": known,
            "budget": budget,
            "total": total,
            "main": by_tag["main"],
            "optional": by_tag["optional"],
            "ratio": (total / budget) if budget else 0.0,
            "missing_xp": sorted(missing),
        }
        return levels, info

    def _warning_checks(self, route: dict[str, Any], report: Report) -> dict[str, Any]:
        world = self.world
        steps = route["steps"]
        levels, xp = self._expected_levels(route)
        # XP range
        if xp["total"] and not (XP_LOW <= xp["ratio"] <= XP_HIGH):
            self._add(
                report,
                WARNING,
                "W_XP_RANGE",
                f"quest XP is {xp['ratio'] * 100:.0f}% of the band budget ({xp['total']} of "
                f"{xp['budget']}); aim for {XP_LOW * 100:.0f}-{XP_HIGH * 100:.0f}%. "
                + (
                    "Add more main/optional quests."
                    if xp["ratio"] < XP_LOW
                    else "Move some quests to optional or drop them."
                ),
            )
        elif not xp["total"]:
            self._add(
                report,
                WARNING,
                "W_XP_RANGE",
                "no quest XP is known for any turned-in quest; the XP budget cannot be checked.",
            )
        # mobs far above the expected level
        for i, step in enumerate(steps):
            if not xp["known"]:
                break  # expected levels are only a guess without XP data
            if step["type"] != "COMPLETE" or step["tag"] == "optional-elite":
                continue
            quest = world.quests.get(step["quest"])
            if not quest:
                continue
            level = int(levels[i])
            for npc_id in self._objective_creatures(quest):
                npc = world.npcs.get(npc_id)
                mob_level = int((npc or {}).get("minLevel") or 0)
                if mob_level and mob_level - level >= MOB_LEVEL_MARGIN:
                    self._add(
                        report,
                        WARNING,
                        "W_MOB_LEVEL",
                        f"objective mob {npc['name']} is level {mob_level}; the player is expected "
                        f"to be about level {level} here. Move the quest later, mark it "
                        "optional-elite with revisitAt, or drop it.",
                        route,
                        i,
                    )
                    break
        visits = self._hub_warnings(route, report)
        cadence = self._trainer_warnings(route, report, levels)
        return {"visits": visits, "trainer": cadence}

    @staticmethod
    def _objective_creatures(quest: dict[str, Any]) -> list[int]:
        out: list[int] = []
        objectives = quest.get("objectives") or {}
        for key in ("creature", "killCredit"):
            for row in objectives.get(key) or []:
                if row and isinstance(row[0], int):
                    out.append(row[0])
        return out

    def _hub_warnings(self, route: dict[str, Any], report: Report) -> list[tuple[str, int]]:
        visits = self._hub_visits(route)
        names = [v[0] for v in visits]
        covered_until = -1
        for k in range(len(names) - 2 * ROUND_TRIPS):
            if k <= covered_until:
                continue  # inside a run already reported (A B A B A also reads as B A B A)
            hub = names[k]
            other = names[k + 1]
            window = names[k : k + 2 * ROUND_TRIPS + 1]
            if (
                hub != other
                and all(w == hub for w in window[0::2])
                and all(w == other for w in window[1::2])
            ):
                covered_until = k + 2 * ROUND_TRIPS
                self._add(
                    report,
                    WARNING,
                    "W_BACKTRACK",
                    f"{ROUND_TRIPS + 1} trips to {hub} in a row, each time returning from "
                    f"{other}; batch the quests so you return only once or twice.",
                    route,
                    visits[k + 2 * ROUND_TRIPS][1],
                )
        # excursions: far from the last hub with no way home
        steps = route["steps"]
        base: tuple[int, float, float, str] | None = None
        worst = 0.0
        worst_step = 0
        safe = False
        for i, step in enumerate(steps):
            if step["type"] in ("HEARTH_USE", "FLY"):
                safe = True
            place = self._step_place(step)
            if not place:
                continue
            hub = self._hub_of(route, *place)
            if hub:
                if base is not None and worst > EXCURSION_LIMIT and not safe:
                    self._add(
                        report,
                        WARNING,
                        "W_EXCURSION",
                        f"{worst:.0f} map-% from {base[3]} with no HEARTH_USE or FLY on the way "
                        f"back; add a hearth/flight home or split the trip.",
                        route,
                        worst_step,
                    )
                base = (place[0], place[1], place[2], hub[0])
                worst, safe = 0.0, False
            elif base is not None and base[0] == place[0]:
                d = distance(place[1], place[2], base[1], base[2])
                if d > worst:
                    worst, worst_step = d, i
        return visits

    def _hub_visits(self, route: dict[str, Any]) -> list[tuple[str, int]]:
        """Compressed sequence of (place name, first step index) visited by the route."""
        visits: list[tuple[str, int]] = []
        for i, step in enumerate(route["steps"]):
            place = self._step_place(step)
            if not place:
                continue
            hub = self._hub_of(route, *place)
            name = (
                hub[0]
                if hub
                else f"{self.world.zone_name(place[0])} {int(place[1] // 10)}{int(place[2] // 10)}"
            )
            if not visits or visits[-1][0] != name:
                visits.append((name, i))
        return visits

    def _trainer_warnings(
        self, route: dict[str, Any], report: Report, levels: list[float]
    ) -> dict[str, Any]:
        lo, hi = route["band"]
        trainers = [(i, s) for i, s in enumerate(route["steps"]) if s["type"] == "TRAINER"]
        groups: dict[str, list[tuple[int, dict[str, Any]]]] = {"ALL": []}
        for item in trainers:
            for cls in item[1].get("classes") or ["ALL"]:
                groups.setdefault(cls, []).append(item)
        cadence: dict[str, Any] = {}
        for cls, items in sorted(groups.items()):
            pool = (
                items if cls == "ALL" else sorted(items + groups["ALL"], key=lambda item: item[0])
            )
            marks = [(float(lo), None)] + [(levels[i], i) for i, _ in pool] + [(float(hi), None)]
            gap, at = 0.0, None
            for (a, _), (b, idx) in zip(marks, marks[1:], strict=False):
                if b - a > gap:
                    gap, at = b - a, idx
            cadence[cls] = {"visits": len(pool), "maxGap": round(gap, 1)}
            if cls == "ALL" and not trainers:
                continue
            if cls != "ALL" and not items:
                continue
            if gap > TRAINER_GAP:
                label = "any class" if cls == "ALL" else cls
                self._add(
                    report,
                    WARNING,
                    "W_TRAINER_GAP",
                    f"trainer gap of about {gap:.1f} levels ({label}); add TRAINER steps at "
                    "even levels (every 2 levels, at most 3 apart).",
                    route,
                    at,
                )
        if not trainers:
            self._add(
                report,
                WARNING,
                "W_TRAINER_GAP",
                f"no TRAINER step in levels {lo}-{hi}; add one at each even level.",
            )
        return cadence

    # ---- review notes ------------------------------------------------------------------

    def _apply_reviews(self, route: dict[str, Any], report: Report) -> None:
        def as_text(value: Any) -> str:
            return "; ".join(value) if isinstance(value, list) else str(value)

        for issue in report.issues:
            if issue.severity != WARNING:
                continue
            if issue.step is None and "_review" in route:
                issue.reviewed = as_text(route["_review"])
            elif issue.step is not None and "_review" in route["steps"][issue.step - 1]:
                issue.reviewed = as_text(route["steps"][issue.step - 1]["_review"])

    # ---- stats -------------------------------------------------------------------------

    def _stats(
        self, route: dict[str, Any], paths: list[PathState], private: dict[str, Any]
    ) -> dict[str, Any]:
        steps = route["steps"]
        by_type = Counter(s["type"] for s in steps)
        tags: dict[str, set[int]] = {"main": set(), "optional": set(), "optional-elite": set()}
        for s in steps:
            if s["type"] == "ACCEPT":
                tags[s["tag"]].add(s["quest"])
        _levels, xp = self._expected_levels(route)
        visits = private["visits"]
        names = [v[0] for v in visits]
        round_trips = sum(
            1
            for k in range(len(names) - 2)
            if names[k] == names[k + 2] and names[k] != names[k + 1]
        )
        return {
            "steps": len(steps),
            "byType": dict(sorted(by_type.items())),
            "quests": {tag: len(ids) for tag, ids in tags.items()},
            "dropped": len(route["dropped"]),
            "xp": xp,
            "hubVisits": len(visits),
            "hubRoundTrips": round_trips,
            "trainer": private["trainer"],
            "paths": [p.label for p in paths],
        }


# ---- orchestration -------------------------------------------------------------------------


def validate_route(
    route: dict[str, Any],
    world: World,
    routes: dict[str, dict[str, Any]] | None = None,
    *,
    stitched: bool = False,
    file: str = "",
) -> Report:
    store = dict(routes or {})
    if isinstance(route.get("id"), str):
        store[route["id"]] = route
    return RouteValidator(world, store, stitched=stitched).validate(route, file)


def validate_set(
    routes: dict[str, dict[str, Any]],
    world: World,
    *,
    stitched: bool = False,
    files: dict[str, str] | None = None,
) -> list[Report]:
    """Validate every route in ``routes`` (id -> route) against the same store."""
    validator = RouteValidator(world, routes, stitched=stitched)
    reports = [
        validator.validate(route, (files or {}).get(rid, "")) for rid, route in routes.items()
    ]
    if stitched:
        reports.extend(global_stitch_reports(routes, world))
    return reports


def global_stitch_reports(routes: dict[str, dict[str, Any]], world: World) -> list[Report]:
    report = Report(route_id="(stitched path)")
    shared = world.faction.shared_track
    branches = {r["branch"] for r in routes.values()} - {shared}
    for branch in sorted(branches):
        roots = [r for r in routes.values() if r["branch"] == branch and r["band"][0] <= 1]
        if not roots:
            report.issues.append(
                Issue(ERROR, "E_STITCH_NO_ROOT", f"branch '{branch}' has no level 1 route.")
            )
            continue
        for root in roots:
            seen: set[str] = set()
            current: dict[str, Any] | None = root
            while current and current["id"] not in seen:
                seen.add(current["id"])
                current = routes.get(current.get("next") or "")
            top = max(routes[i]["band"][1] for i in seen)
            if top < world.faction.levels[1]:
                report.issues.append(
                    Issue(
                        ERROR,
                        "E_STITCH_NO_END",
                        f"following `next` from {root['id']} stops at level {top}, never reaching "
                        f"level {world.faction.levels[1]}.",
                    )
                )
    return [report] if report.issues else []


# ---- formatting ----------------------------------------------------------------------------


def format_report(report: Report, *, stats: bool = True) -> str:
    lines = [f"== {report.route_id}" + (f"  ({report.file})" if report.file else "")]
    route_level = [i for i in report.issues if i.step is None]
    for issue in route_level:
        lines.append(f"  {_tag(issue)} route: {issue.message}{_reviewed(issue)}")
    current: int | None = None
    for issue in (i for i in report.issues if i.step is not None):
        if issue.step != current:
            current = issue.step
        lines.append(
            f"  {_tag(issue)} step {issue.step} {issue.step_label}: "
            f"{issue.message}{_reviewed(issue)}"
        )
    errors, warnings = len(report.errors), len(report.warnings)
    open_warnings = len([w for w in report.warnings if w.reviewed is None])
    lines.append(
        f"  result: {'OK' if not errors else 'FAILED'} - {errors} error(s), {warnings} warning(s)"
        + (f" ({open_warnings} unreviewed)" if warnings else "")
    )
    if stats and report.stats:
        lines.extend(format_stats(report.stats))
    return "\n".join(lines)


def _tag(issue: Issue) -> str:
    return ("ERROR" if issue.severity == ERROR else "warn ") + f" {issue.code}"


def _reviewed(issue: Issue) -> str:
    return f"  [reviewed: {issue.reviewed}]" if issue.reviewed is not None else ""


def format_stats(stats: dict[str, Any]) -> list[str]:
    xp = stats["xp"]
    types = ", ".join(f"{k} {v}" for k, v in stats["byType"].items())
    quests = stats["quests"]
    pct = f"{xp['ratio'] * 100:.0f}%" if xp["budget"] else "n/a"
    trainer = ", ".join(
        f"{cls}: {t['visits']} visit(s), max gap {t['maxGap']}"
        for cls, t in stats["trainer"].items()
    )
    lines = [
        "  stats:",
        f"    steps: {stats['steps']} ({types})",
        f"    quests: main {quests['main']}, optional {quests['optional']}, "
        f"optional-elite {quests['optional-elite']}, dropped {stats['dropped']}",
        f"    xp: {xp['total']} of budget {xp['budget']} ({pct}); main {xp['main']}, "
        f"optional {xp['optional']}"
        + (f"; no XP data for {len(xp['missing_xp'])} quest(s)" if xp["missing_xp"] else ""),
        f"    hubs: {stats['hubVisits']} visits, {stats['hubRoundTrips']} round-trip(s)",
        f"    trainer cadence: {trainer}",
    ]
    return lines


def validate_curated(data: dict[str, Any], world: World | None = None) -> list[Issue]:
    """Schema-check a curation file; with a world, also check ids and pack coverage."""
    schema = Draft202012Validator(json.loads(CURATED_SCHEMA_PATH.read_text(encoding="utf-8")))
    issues = [
        Issue(
            ERROR,
            "E_SCHEMA",
            f"schema: {e.message} [at {'/'.join(map(str, e.absolute_path)) or '(root)'}]",
        )
        for e in schema.iter_errors(data)
    ]
    if issues or world is None:
        return issues
    seen: set[int] = set()
    for row in data["decisions"]:
        if row["quest"] not in world.quests:
            issues.append(
                Issue(ERROR, "E_UNKNOWN_QUEST", f"quest {row['quest']} is not in the DB.")
            )
        if row["quest"] in seen:
            issues.append(Issue(ERROR, "E_DUPLICATE", f"quest {row['quest']} has two decisions."))
        seen.add(row["quest"])
    rid = str(data["id"])
    pack = world.pack(rid.split("_", 1)[1] if "_" in rid else rid)
    if pack is not None:
        missing = sorted({q["i"] for q in pack["quests"]} - seen)
        if missing:
            issues.append(
                Issue(
                    ERROR,
                    "E_UNACCOUNTED",
                    f"{len(missing)} pack quest(s) have no decision: {missing[:25]}",
                )
            )
        for q in pack["quests"]:
            decisions = {r["quest"]: r["decision"] for r in data["decisions"]}
            if (
                "elite" in q.get("fl", [])
                and decisions.get(q["i"]) == "drop"
                and not world.unplaceable(q["i"])
            ):
                issues.append(
                    Issue(
                        ERROR,
                        "E_ELITE_DROPPED",
                        f"quest {q['i']} is elite and cannot be dropped; use optional-elite.",
                    )
                )
    return issues
