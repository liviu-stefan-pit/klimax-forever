"""Graph validator for the compiled world (``python -m pipeline validate --world``).

Errors fail the gate (``compile-world`` refuses to write); warnings are listed; infos are only
counted. Quests the corrections mark ``broken`` or ``skip`` are never planned, so graph errors on
them are reported as infos; a ``review`` status turns that quest's warnings into reviewed infos.

Checks (code: meaning):

* ``E_MISSING_ENTITY``: a starter, finisher or objective names an NPC, object or item that is not
  in the extract.
* ``E_UNRESOLVED`` / ``E_DUP_DEFINITION`` / ``E_DUP_QUEST`` / ``E_DUP_HUB``: every referenced
  NPC and object is defined in exactly one file, every quest in one zone, hub ids are unique.
* ``E_IMPOSSIBLE_PREREQ``: an all-of prerequisite the faction cannot take, an any-of list with no
  option the faction can take, or no race/class left that can do the quest and its prerequisites.
* ``E_UNREACHABLE``: no starter with a position (an NPC or object in a dungeon counts, it is
  reached through the entrance), or a prerequisite that is itself unreachable.
  ``W_ITEM_START_UNPLACED``: the starters are items and none has a located source (the item may
  come from a source the data does not list, so it does not block the graph).
* ``E_TURNIN_UNPLACED``: turn-in NPCs or objects are listed but none has a position.
* ``E_CYCLE``: prerequisites that depend on each other.
* ``E_CHAIN_MISSING``: ``nextQuestInChain`` names a quest that is not in the extract;
  ``W_CHAIN_OUT``: it names a quest the faction cannot take (an orphaned chain link).
* ``W_NO_FINISHER``: the data lists no turn-in at all.
* ``W_SAME_NAME``: two compiled quests share a name and can be taken by the same character,
  without a chain, exclusive group, equivalent group or ``notDuplicates`` entry relating them.
* ``W_SPAWN_SPREAD``: a quest giver or turn-in NPC spawns at places far apart in one zone.
* ``E_SIZE`` / ``W_SIZE``: per-file size budget. ``E_STALE``: a generated file differs from a
  fresh compile (run ``compile-world``).
* ``E_CORRECTION``: a correction names an unknown quest or NPC.
* infos: ``I_PREREQ_OUTSIDE`` (prerequisite in a zone that is not compiled), ``I_NEGATIVE_PREREQ``,
  ``I_PREREQ_LEVEL`` (prerequisites need a higher level; the record carries it as ``re``) and
  ``I_OBJECTIVE_UNPLACED`` (an objective with no known position, e.g. inside a dungeon).
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from pipeline.shape.coords import dist, valid_spawns
from pipeline.world.build import OUTSIDE, WorldModel

ERROR, WARNING, INFO = "error", "warning", "info"
SPAWN_SPREAD = 10.0  # map-%: giver spawns further apart than this in one zone are ambiguous
QUIET_STATUSES = ("broken", "skip")


@dataclass(frozen=True)
class GraphIssue:
    severity: str
    code: str
    message: str
    quest: int | None = None
    zone: str = ""
    reviewed: bool = False

    def as_dict(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "message": self.message,
            "quest": self.quest,
            "reviewed": self.reviewed,
            "severity": self.severity,
            "zone": self.zone,
        }


@dataclass
class GraphReport:
    issues: list[GraphIssue] = field(default_factory=list)
    stats: dict[str, Any] = field(default_factory=dict)

    @property
    def errors(self) -> list[GraphIssue]:
        return [i for i in self.issues if i.severity == ERROR]

    @property
    def warnings(self) -> list[GraphIssue]:
        return [i for i in self.issues if i.severity == WARNING]

    @property
    def infos(self) -> list[GraphIssue]:
        return [i for i in self.issues if i.severity == INFO]

    @property
    def ok(self) -> bool:
        return not self.errors


class _Collector:
    def __init__(self, model: WorldModel) -> None:
        self.issues: list[GraphIssue] = []
        self.status = model.corrections.quest_status()
        self.zone_of = model.index["quests"]
        self.names = {z.ui_map: z.name for z in model.zones}

    def add(self, severity: str, code: str, message: str, quest: int | None = None) -> None:
        zone = self.names.get(self.zone_of.get(quest, -1), "") if quest else ""
        reviewed = False
        status = self.status.get(quest) if quest else None
        if status in QUIET_STATUSES and severity in (ERROR, WARNING):
            severity, reviewed = INFO, True
        elif status == "review" and severity == WARNING:
            severity, reviewed = INFO, True
        self.issues.append(GraphIssue(severity, code, message, quest, zone, reviewed))


def validate_world(
    model: WorldModel, files: dict[Path, str] | None = None, check_disk: bool = False
) -> GraphReport:
    """Check the model, and, given the generated ``files``, their sizes (and with
    ``check_disk`` whether the files on disk match them)."""
    out = _Collector(model)
    _check_corrections(model, out)
    _check_definitions(model, out)
    _check_quests(model, out)
    _check_same_names(model, out)
    if files is not None:
        _check_files(model, files, check_disk, out)
    issues = sorted(
        out.issues,
        key=lambda i: (
            {ERROR: 0, WARNING: 1, INFO: 2}[i.severity],
            i.code,
            i.quest or 0,
            i.message,
        ),
    )
    stats = _stats(model, files)
    return GraphReport(issues=issues, stats=stats)


# ---- checks ------------------------------------------------------------------------------------


def _check_corrections(model: WorldModel, out: _Collector) -> None:
    raw = model.graph.raw
    for qid in sorted(model.corrections.referenced_quest_ids()):
        if qid not in raw.quests:
            out.add(ERROR, "E_CORRECTION", f"corrections name quest {qid}, which is not in the DB")
    for row in model.corrections.npc_positions:
        if int(row["npc"]) not in raw.npcs:
            out.add(ERROR, "E_CORRECTION", f"npcPositions names NPC {row['npc']}, not in the DB")
        if row["zone"] not in raw.zone_by_name:
            out.add(ERROR, "E_CORRECTION", f"npcPositions zone '{row['zone']}' is unknown")


def _check_definitions(model: WorldModel, out: _Collector) -> None:
    defined: dict[tuple[str, int], list[int]] = defaultdict(list)
    for ui_map, table in model.tables.items():
        for nid in table["npcs"]:
            defined[("n", nid)].append(ui_map)
        for oid in table["objects"]:
            defined[("o", oid)].append(ui_map)
    for (kind, ident), zones in sorted(defined.items()):
        if len(zones) > 1:
            out.add(ERROR, "E_DUP_DEFINITION", f"{kind}{ident} is defined in zones {zones}")
    quest_zones: dict[int, list[int]] = defaultdict(list)
    hub_ids: dict[str, int] = defaultdict(int)
    for ui_map, table in model.tables.items():
        if ui_map == OUTSIDE:
            continue
        for qid in table["quests"]:
            quest_zones[qid].append(ui_map)
        for hub in table["hubs"]:
            hub_ids[hub["id"]] += 1
            for nid in hub.get("npcs", []):
                if ("n", nid) not in defined:
                    out.add(ERROR, "E_UNRESOLVED", f"hub {hub['id']} member n{nid} is not defined")
    for qid, zones in sorted(quest_zones.items()):
        if len(zones) > 1:
            out.add(ERROR, "E_DUP_QUEST", f"quest {qid} is compiled in zones {zones}", qid)
    for hub_id, count in sorted(hub_ids.items()):
        if count > 1:
            out.add(ERROR, "E_DUP_HUB", f"hub id {hub_id} is used {count} times")
    for _ui_map, table in sorted(model.tables.items()):
        for qid, quest in sorted(table.get("quests", {}).items()):
            refs = [("n", i) for k in ("sn", "en") for i in quest.get(k, [])]
            refs += [("o", i) for k in ("so", "eo") for i in quest.get(k, [])]
            for obj in quest.get("o", []):
                if obj["k"] == "c" and "id" in obj:
                    refs.append(("n", obj["id"]))
                elif obj["k"] == "o" and "id" in obj:
                    refs.append(("o", obj["id"]))
                refs += [("n", s) for s in obj.get("src", [])]
            raw = model.graph.raw
            for kind, ident in refs:
                table_raw = raw.npcs if kind == "n" else raw.objects
                if ident not in table_raw:
                    out.add(ERROR, "E_MISSING_ENTITY", f"{kind}{ident} is not in the DB", qid)
                elif (kind, ident) not in defined:
                    out.add(ERROR, "E_UNRESOLVED", f"{kind}{ident} is not defined in any file", qid)
            for iid in quest.get("si", []):
                if iid not in raw.items:
                    out.add(ERROR, "E_MISSING_ENTITY", f"starter item {iid} is not in the DB", qid)


def _check_quests(model: WorldModel, out: _Collector) -> None:
    graph = model.graph
    raw = graph.raw
    compiled = set(model.index["quests"])
    cycle_members = {q for cycle in graph.cycles for q in cycle}
    for cycle in graph.cycles:
        if compiled & set(cycle):
            first = min(q for q in cycle if q in compiled)
            out.add(ERROR, "E_CYCLE", f"prerequisite cycle: {cycle}", first)
    for qid in sorted(compiled):
        quest = graph.quests[qid]
        pre = graph.prereqs(qid)
        rl = max(int(quest.raw.get("requiredLevel", 0)), 1)
        for p in pre.all_of:
            if p not in graph.quests:
                why = "not in the DB" if p not in raw.quests else "not available to the faction"
                out.add(ERROR, "E_IMPOSSIBLE_PREREQ", f"needs quest {p}, {why}", qid)
            elif p not in compiled:
                out.add(
                    INFO, "I_PREREQ_OUTSIDE", f"prerequisite {p} is in a zone not compiled", qid
                )
        if pre.any_of and not any(p in graph.quests for p in pre.any_of):
            out.add(
                ERROR,
                "E_IMPOSSIBLE_PREREQ",
                f"needs one of {pre.any_of}, none available to the faction",
                qid,
            )
        effective = graph.required_level(qid)
        if effective > rl:
            out.add(
                INFO,
                "I_PREREQ_LEVEL",
                f"prerequisites need level {effective}, the quest only {rl}",
                qid,
            )
        if pre.negative:
            out.add(INFO, "I_NEGATIVE_PREREQ", f"negative prerequisite ids {pre.negative}", qid)
        if graph.races(qid) == 0 or graph.classes(qid) == 0:
            out.add(
                ERROR,
                "E_IMPOSSIBLE_PREREQ",
                "no race/class can do both the quest and its prerequisites",
                qid,
            )
        if not any(graph.located(r) for r in quest.starters):
            if all(k == "i" for k, _ in quest.starters):
                out.add(
                    WARNING,
                    "W_ITEM_START_UNPLACED",
                    f"no source with a position for starter item(s) {quest.starters}",
                    qid,
                )
            else:
                out.add(ERROR, "E_UNREACHABLE", f"no starter with a position {quest.starters}", qid)
        elif not graph.reachable[qid] and qid not in cycle_members:
            blocked = [
                p
                for p in (*pre.all_of, *pre.any_of)
                if p in graph.quests and not graph.reachable[p]
            ]
            out.add(ERROR, "E_UNREACHABLE", f"blocked by unreachable prerequisites {blocked}", qid)
        state = graph.finisher_state(qid)
        if state == "unplaced":
            out.add(ERROR, "E_TURNIN_UNPLACED", f"turn-in {quest.finishers} has no position", qid)
        elif state == "none":
            out.add(WARNING, "W_NO_FINISHER", "the DB lists no turn-in", qid)
        nxt = graph.next.get(qid)
        if nxt:
            if nxt not in raw.quests:
                out.add(ERROR, "E_CHAIN_MISSING", f"next quest {nxt} is not in the DB", qid)
            elif nxt not in graph.quests:
                out.add(WARNING, "W_CHAIN_OUT", f"next quest {nxt} is not available", qid)
        for kind, ident in (*quest.starters, *quest.finishers):
            if kind != "n":
                continue
            spread = _spread(valid_spawns(raw.npcs.get(ident, {}).get("spawns")))
            if spread > SPAWN_SPREAD:
                out.add(
                    WARNING,
                    "W_SPAWN_SPREAD",
                    f"n{ident} spawns up to {spread:.0f} map-% apart in one zone",
                    qid,
                )
        record = model.tables[model.index["quests"][qid]]["quests"][qid]
        for obj in record.get("o", []):
            if obj["k"] in ("c", "o", "i") and "at" not in obj:
                out.add(INFO, "I_OBJECTIVE_UNPLACED", f"objective {obj['k']}{obj.get('id')}", qid)


def _spread(points: list[tuple[int, float, float]]) -> float:
    best = 0.0
    by_zone: dict[int, list[tuple[float, float]]] = defaultdict(list)
    for zone, x, y in points:
        by_zone[zone].append((x, y))
    for pts in by_zone.values():
        for i, a in enumerate(pts):
            for b in pts[i + 1 :]:
                best = max(best, dist(a, b))
    return best


def _related(model: WorldModel, a: int, b: int) -> bool:
    graph = model.graph
    if graph.chain_head(a) is not None and graph.chain_head(a) == graph.chain_head(b):
        return True
    group = graph.exclusive_group(a)
    if group is not None and group == graph.exclusive_group(b):
        return True
    pa, pb = graph.prereqs(a), graph.prereqs(b)
    if b in (*pa.all_of, *pa.any_of) or a in (*pb.all_of, *pb.any_of):
        return True
    for ids in (*model.corrections.equivalent_groups(), *model.corrections.not_duplicate_groups()):
        if a in ids and b in ids:
            return True
    return False


def _check_same_names(model: WorldModel, out: _Collector) -> None:
    graph = model.graph
    by_name: dict[str, list[int]] = defaultdict(list)
    for qid in sorted(model.index["quests"]):
        by_name[str(graph.raw.quests[qid].get("name", ""))].append(qid)
    for name, ids in sorted(by_name.items()):
        for i, a in enumerate(ids):
            for b in ids[i + 1 :]:
                if not (graph.races(a) & graph.races(b)) or not (
                    graph.classes(a) & graph.classes(b)
                ):
                    continue
                if _related(model, a, b):
                    continue
                out.add(
                    WARNING,
                    "W_SAME_NAME",
                    f"'{name}' is also quest {b} for the same characters; curate it as "
                    "equivalent or not a duplicate",
                    a,
                )


def _check_files(
    model: WorldModel, files: dict[Path, str], check_disk: bool, out: _Collector
) -> None:
    config = model.config
    for path in sorted(files):
        size = len(files[path].encode("utf-8"))
        if size > config.size_budget:
            out.add(ERROR, "E_SIZE", f"{path.name} is {size} bytes (budget {config.size_budget})")
        elif size > config.size_warn:
            out.add(WARNING, "W_SIZE", f"{path.name} is {size} bytes (warn at {config.size_warn})")
        if check_disk:
            if not path.exists():
                out.add(ERROR, "E_STALE", f"{path.as_posix()} is missing; run compile-world")
            elif path.read_text(encoding="utf-8") != files[path]:
                out.add(ERROR, "E_STALE", f"{path.as_posix()} is out of date; run compile-world")


def _stats(model: WorldModel, files: dict[Path, str] | None) -> dict[str, Any]:
    zones: dict[str, Any] = {}
    for zone in model.zones:
        table = model.tables[zone.ui_map]
        zones[zone.name] = {
            "hubs": len(table["hubs"]),
            "npcs": len(table["npcs"]),
            "objects": len(table["objects"]),
            "quests": len(table["quests"]),
        }
    stats: dict[str, Any] = {"zones": zones, "left out": dict(sorted(model.stats.items()))}
    if files is not None:
        stats["bytes"] = {p.name: len(t.encode("utf-8")) for p, t in sorted(files.items())}
    return stats


def format_graph_report(report: GraphReport, limit: int = 200) -> str:
    lines = ["== world graph"]
    shown = [i for i in report.issues if i.severity != INFO]
    for issue in shown[:limit]:
        tag = "E" if issue.severity == ERROR else "W"
        where = f" quest {issue.quest} ({issue.zone})" if issue.quest else ""
        lines.append(f"  {tag} {issue.code}{where}: {issue.message}")
    if len(shown) > limit:
        lines.append(f"  ... {len(shown) - limit} more (use --json)")
    infos: dict[str, int] = defaultdict(int)
    for issue in report.infos:
        infos[issue.code + (" (reviewed)" if issue.reviewed else "")] += 1
    if infos:
        lines.append("  infos: " + ", ".join(f"{k} x{v}" for k, v in sorted(infos.items())))
    for name, row in report.stats.get("zones", {}).items():
        lines.append(
            f"  {name}: {row['quests']} quests, {row['npcs']} NPCs, {row['objects']} objects, "
            f"{row['hubs']} hubs"
        )
    if "bytes" in report.stats:
        sizes = ", ".join(f"{k} {v // 1024} KB" for k, v in report.stats["bytes"].items())
        lines.append(f"  files: {sizes}")
    lines.append(
        f"\nworld graph: {len(report.errors)} error(s), {len(report.warnings)} warning(s), "
        f"{len(report.infos)} info(s)."
    )
    return "\n".join(lines)
