"""Quest graph builder.

Works over every quest the faction can take (``ShapeContext.quests``, the phase 02 filters), not
only the compiled zones, so prerequisites and chains that leave a zone still resolve. It
resolves:

* prerequisites: ``preQuestGroup`` (all of) and ``preQuestSingle`` (any of), without the quest
  itself and its exclusive siblings (QuestieDB lists them in preQuestSingle); negative ids are
  kept apart (QuestieDB uses two of them; their meaning is not documented, so they never gate);
* exclusive groups (``exclusiveTo``, closed transitively) with the smallest id as group id;
* chains (``nextQuestInChain`` and its inverse) with the head quest id as chain id;
* effective race and class masks: a quest is only open to the races and classes that can also
  do its prerequisites (all of: intersection, any of: union);
* placement and reachability: a starter or finisher is placed when it has a usable spawn (items:
  a placed drop source, or another quest rewards it); a quest is reachable when it is placed and
  its prerequisites are reachable;
* XP at the player's level (:func:`xp_at_level`) and rewards.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any

from pipeline.shape.context import ShapeContext, effective_level, objective_text
from pipeline.shape.factions import CLASS_BITS

ALL_CLASSES = 0
for _bit in CLASS_BITS.values():
    ALL_CLASSES |= _bit


# Quest sort keys (negative zoneOrSort) of holidays, world events and reputation turn-ins, from
# QuestieDB ``corrections/enum/quests.lua``: Winter Veil, Harvest Festival, Children's Week, Love
# is in the Air, Pilgrim's Bounty, Noblegarden, Brewfest, Midsummer, Lunar Festival, Darkmoon
# Faire, Day of the Dead, Seasonal, Hallow's End, Invasion, Ahn'Qiraj war, Battlegrounds,
# Reputation (commendation signets).
EVENT_SORTS = frozenset(
    {-404, -402, -378, -376, -375, -374, -370, -369, -366, -364, -41, -22, -21, -368, -365, -25,
     -367}
)  # fmt: skip


def is_event(row: dict[str, Any]) -> bool:
    """Holiday, world-event or turn-in quest that is not part of leveling. Also catches the level
    60 quests that low levels can take (cloth donations, Children's Week, Darkmoon Faire): in
    Classic data a level 60 quest that needs 20 or more levels less is never a leveling quest."""
    if int(row.get("zoneOrSort", 0)) in EVENT_SORTS:
        return True
    level, required = int(row.get("questLevel", 0)), int(row.get("requiredLevel", 0))
    return level >= 60 and level - required >= 20


def xp_at_level(base_xp: int, quest_level: int, player_level: int) -> int:
    """Classic quest XP for a player level: full up to 5 levels above the quest, then 80, 60, 40,
    20 and 10 percent; rounded down to a multiple of 5 (the client shows rounded values)."""
    diff = player_level - quest_level
    factor = {6: 0.8, 7: 0.6, 8: 0.4, 9: 0.2}.get(diff, 1.0 if diff <= 5 else 0.1)
    return int(base_xp * factor) // 5 * 5


@dataclass
class Prereqs:
    all_of: list[int] = field(default_factory=list)
    any_of: list[int] = field(default_factory=list)
    negative: list[int] = field(default_factory=list)


class QuestGraph:
    """Graph over ``ctx.quests`` (call ``ctx.build_quests()`` first)."""

    def __init__(self, ctx: ShapeContext) -> None:
        self.ctx = ctx
        self.raw = ctx.raw
        self.quests = ctx.quests
        self.race_all = ctx.cfg.race_mask
        self.cycles: list[list[int]] = []
        self._prereqs: dict[int, Prereqs] = {}
        self._race: dict[int, int] = {}
        self._class: dict[int, int] = {}
        self._required: dict[int, int] = {}
        self._exclusive = self._exclusive_groups()
        self.next: dict[int, int] = {}
        self.prev: dict[int, list[int]] = defaultdict(list)
        for qid in sorted(self.quests):
            nxt = int(self.raw.quests[qid].get("nextQuestInChain") or 0)
            if nxt > 0:
                self.next[qid] = nxt
                if nxt in self.quests:
                    self.prev[nxt].append(qid)
        self._chains = self._chain_components()
        self._rewarded_items = {
            iid for qid in self.quests for iid in self.raw.quests[qid].get("rewardItemIds") or []
        }
        self.reachable = self._reachability()

    # ---- prerequisites, groups, chains ----------------------------------------------------------

    def prereqs(self, qid: int) -> Prereqs:
        if qid in self._prereqs:
            return self._prereqs[qid]
        row = self.raw.quests.get(qid, {})
        own = {qid, *(int(x) for x in row.get("exclusiveTo") or [])}
        out = Prereqs()
        for key, target in (("preQuestGroup", out.all_of), ("preQuestSingle", out.any_of)):
            for value in row.get(key) or []:
                value = int(value)
                if value < 0:
                    out.negative.append(value)
                elif value not in own:
                    target.append(value)
        out.all_of = sorted(set(out.all_of))
        out.any_of = sorted(set(out.any_of))
        out.negative = sorted(set(out.negative))
        # parentQuest is not a completion prerequisite (the parent must be active); it is kept in
        # the record as ``pq`` only.
        self._prereqs[qid] = out
        return out

    def _exclusive_groups(self) -> dict[int, int]:
        """quest id -> group id (smallest member), closed over ``exclusiveTo`` links."""
        parent: dict[int, int] = {}

        def find(x: int) -> int:
            while parent.setdefault(x, x) != x:
                parent[x] = parent[parent[x]]
                x = parent[x]
            return x

        for qid in sorted(self.quests):
            for other in self.raw.quests[qid].get("exclusiveTo") or []:
                other = int(other)
                if other in self.quests and other != qid:
                    a, b = find(qid), find(other)
                    if a != b:
                        parent[max(a, b)] = min(a, b)
        groups: dict[int, list[int]] = defaultdict(list)
        for qid in parent:
            groups[find(qid)].append(qid)
        out: dict[int, int] = {}
        for members in groups.values():
            if len(members) > 1:
                gid = min(members)
                out.update({m: gid for m in members})
        return out

    def exclusive_group(self, qid: int) -> int | None:
        return self._exclusive.get(qid)

    def exclusive_groups(self) -> dict[int, list[int]]:
        out: dict[int, list[int]] = defaultdict(list)
        for qid, gid in self._exclusive.items():
            out[gid].append(qid)
        return {gid: sorted(ids) for gid, ids in sorted(out.items())}

    def _chain_components(self) -> dict[int, int]:
        """quest id -> chain id for quests linked by ``nextQuestInChain`` (undirected
        components). The chain id is the smallest member without a predecessor (the head), so
        branching chains that merge (Call of Fire: four starts, one path) share one id."""
        parent: dict[int, int] = {}

        def find(x: int) -> int:
            while parent.setdefault(x, x) != x:
                parent[x] = parent[parent[x]]
                x = parent[x]
            return x

        for qid, nxt in sorted(self.next.items()):
            if nxt in self.quests:
                a, b = find(qid), find(nxt)
                if a != b:
                    parent[max(a, b)] = min(a, b)
        members: dict[int, list[int]] = defaultdict(list)
        for qid in parent:
            members[find(qid)].append(qid)
        out: dict[int, int] = {}
        for ids in members.values():
            heads = [q for q in ids if not self.prev.get(q)] or ids
            out.update({q: min(heads) for q in ids})
        return out

    def chain_head(self, qid: int) -> int | None:
        """Chain id (head quest) of the chain the quest is in, or None if it is in none."""
        return self._chains.get(qid)

    # ---- effective masks ------------------------------------------------------------------------

    def own_races(self, qid: int) -> int:
        mask = int(self.raw.quests[qid].get("requiredRaces", 0)) & self.race_all
        return mask or self.race_all

    def own_classes(self, qid: int) -> int:
        mask = int(self.raw.quests[qid].get("requiredClasses", 0)) & ALL_CLASSES
        return mask or ALL_CLASSES

    def races(self, qid: int) -> int:
        return self._effective(qid, self._race, self.own_races, [])

    def classes(self, qid: int) -> int:
        return self._effective(qid, self._class, self.own_classes, [])

    def _effective(self, qid: int, memo: dict[int, int], own: Any, stack: list[int]) -> int:
        if qid in memo:
            return memo[qid]
        if qid not in self.quests:
            return 0
        if qid in stack:
            cycle = stack[stack.index(qid) :]
            key = sorted(cycle)
            if key not in self.cycles:
                self.cycles.append(key)
            return own(qid)
        stack.append(qid)
        mask = own(qid)
        pre = self.prereqs(qid)
        for p in pre.all_of:
            if p in self.quests:
                mask &= self._effective(p, memo, own, stack)
        if pre.any_of:
            alt = 0
            for p in pre.any_of:
                if p in self.quests:
                    alt |= self._effective(p, memo, own, stack)
            if any(p in self.quests for p in pre.any_of):
                mask &= alt
        stack.pop()
        memo[qid] = mask
        return mask

    def required_level(self, qid: int, stack: tuple[int, ...] = ()) -> int:
        """Lowest level at which the quest can be taken, counting its prerequisites (all of: the
        highest, any of: the lowest option)."""
        if qid in self._required:
            return self._required[qid]
        own = max(int(self.raw.quests[qid].get("requiredLevel", 0)), 1)
        if qid in stack:
            return own
        pre = self.prereqs(qid)
        level = own
        for p in pre.all_of:
            if p in self.quests:
                level = max(level, self.required_level(p, (*stack, qid)))
        options = [self.required_level(p, (*stack, qid)) for p in pre.any_of if p in self.quests]
        if options:
            level = max(level, min(options))
        self._required[qid] = level
        return level

    # ---- placement and reachability -------------------------------------------------------------

    def instanced(self, ref: tuple[str, int]) -> bool:
        """An NPC or object whose spawns all lie in dungeon instances (QuestieDB stores them as
        ``[-1, -1]`` in the dungeon's zone). The player reaches it through the dungeon entrance."""
        kind, ident = ref
        table = self.raw.npcs if kind == "n" else self.raw.objects if kind == "o" else {}
        spawns = (table.get(ident) or {}).get("spawns") or {}
        zones = {int(z) for z in spawns}
        return bool(zones) and zones <= self.raw.dungeon_ids

    def located(self, ref: tuple[str, int]) -> bool:
        """Has a usable position: a spawn, an instance, or (items) a located drop source or
        another quest that rewards it."""
        kind, ident = ref
        if kind == "i":
            if ident in self._rewarded_items:
                return True
            npcs, objects = self.ctx.item_sources(ident)
            return any(self.located(("n", n)) for n in npcs) or any(
                self.located(("o", o)) for o in objects
            )
        return bool(self.ctx.entity_points(ref)) or self.instanced(ref)

    def starter_placed(self, qid: int) -> bool:
        """For reachability: a located NPC/object starter, or any item starter (an item can come
        from sources the data does not list; the validator warns when none is located)."""
        return any(r[0] == "i" or self.located(r) for r in self.quests[qid].starters)

    def finisher_state(self, qid: int) -> str:
        """``placed``, ``unplaced`` (finishers listed, none has a position) or ``none``."""
        finishers = [r for r in self.quests[qid].finishers if r[0] != "i"]
        if not finishers:
            return "none"
        return "placed" if any(self.located(r) for r in finishers) else "unplaced"

    def _reachability(self) -> dict[int, bool]:
        """Fixpoint: placed, all-of prerequisites reachable, one any-of reachable (when the list
        names a quest the faction can take). Prerequisites outside the faction set never gate,
        they are reported by the validator instead."""
        reach = {qid: False for qid in self.quests}
        placed = {qid: self.starter_placed(qid) for qid in self.quests}
        changed = True
        while changed:
            changed = False
            for qid in sorted(self.quests):
                if reach[qid] or not placed[qid]:
                    continue
                pre = self.prereqs(qid)
                if any(p in self.quests and not reach[p] for p in pre.all_of):
                    continue
                options = [p for p in pre.any_of if p in self.quests]
                if options and not any(reach[p] for p in options):
                    continue
                reach[qid] = True
                changed = True
        return reach

    # ---- XP -------------------------------------------------------------------------------------

    def xp_by_level(self) -> dict[int, int]:
        """Estimated base XP per quest level 1..60: the median XP of the faction's quests within two
        levels, made non-decreasing. Forever's own quests have no XP row; this is their estimate."""
        values: dict[int, list[int]] = defaultdict(list)
        for qid in self.quests:
            row = self.raw.xp.get(qid)
            if row and row[1] > 0:
                values[effective_level(self.raw.quests[qid])].append(int(row[1]))
        out: dict[int, int] = {}
        last = 0
        for level in range(1, 61):
            window = sorted(v for d in range(-2, 3) for v in values.get(level + d, []))
            if window:
                last = max(last, window[(len(window) - 1) // 2])
            out[level] = last
        return out

    # ---- record ---------------------------------------------------------------------------------

    def record(self, qid: int, point: Any) -> dict[str, Any]:
        """Compact quest record (docs/PRD.md s6.8). ``point(area, x, y)`` turns a zone-area
        position into ``[uiMap, x, y]`` or None when the area has no map."""
        info = self.quests[qid]
        row = info.raw
        out: dict[str, Any] = {"n": str(row.get("name", "")), "lv": effective_level(row)}
        out["rl"] = max(int(row.get("requiredLevel", 0)), 1)
        effective = self.required_level(qid)
        if effective > out["rl"]:
            out["re"] = effective
        if int(row.get("requiredMaxLevel") or 0) > 0:
            out["mx"] = int(row["requiredMaxLevel"])
        for kind, key in (("n", "sn"), ("o", "so"), ("i", "si")):
            ids = sorted({i for k, i in info.starters if k == kind})
            if ids:
                out[key] = ids
        for kind, key in (("n", "en"), ("o", "eo")):
            ids = sorted({i for k, i in info.finishers if k == kind})
            if ids:
                out[key] = ids
        pre = self.prereqs(qid)
        if pre.all_of:
            out["pa"] = pre.all_of
        if pre.any_of:
            out["po"] = pre.any_of
        parent = int(row.get("parentQuest") or 0)
        if parent > 0:
            out["pq"] = parent
        if qid in self.next:
            out["nx"] = self.next[qid]
        if self.prev.get(qid):
            out["pv"] = sorted(self.prev[qid])
        head = self.chain_head(qid)
        if head is not None:
            out["ch"] = head
        group = self.exclusive_group(qid)
        if group is not None:
            out["ex"] = group
        breadcrumb = int(row.get("breadcrumbForQuestId") or 0)
        if breadcrumb > 0:
            out["bc"] = breadcrumb
        races = self.races(qid)
        if races != self.race_all:
            out["ra"] = races
        classes = self.classes(qid)
        if classes != ALL_CLASSES:
            out["cl"] = classes
        xp = self.raw.xp.get(qid)
        if xp and xp[1] > 0:
            out["xp"] = int(xp[1])
        rewards = self.ctx.rewards(qid)
        if rewards:
            out["rw"] = [r["i"] for r in rewards]
            upgrades = [r["i"] for r in rewards if r.get("up")]
            if upgrades:
                out["ru"] = upgrades
        rep = [
            [int(f), int(v)]
            for f, v in (row.get("reputationReward") or [])
            if isinstance(f, int) and isinstance(v, int)
        ]
        if rep:
            out["rp"] = sorted(rep)
        skill = row.get("requiredSkill")
        if isinstance(skill, list) and len(skill) == 2:
            out["sk"] = [int(skill[0]), int(skill[1])]
        flags = sorted(f for f in self.ctx.quest_flags(info) if not f.startswith("class:"))
        if flags:
            out["f"] = flags
        objectives = self.objectives(qid, point)
        if objectives:
            out["o"] = objectives
        text = objective_text(row)
        if text:
            out["t"] = text
        return out

    def objectives(self, qid: int, point: Any) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for obj in self.ctx.objectives(qid):
            entry: dict[str, Any] = {"k": obj["k"]}
            if "i" in obj:
                entry["id"] = int(obj["i"])
            if obj.get("t"):
                entry["t"] = str(obj["t"])
            if "lv" in obj:
                entry["lv"] = list(obj["lv"])
            if obj.get("rk"):
                entry["rk"] = int(obj["rk"])
            if obj.get("src"):
                entry["src"] = [int(s[0]) for s in obj["src"]]
            points = []
            for cluster in obj.get("c", []):
                pos = point(cluster["z"], cluster["x"], cluster["y"])
                if pos is not None:
                    points.append([*pos, cluster["r"], cluster["n"]])
            if points:
                entry["at"] = points
            out.append(entry)
        return out

    def referenced_entities(self, qid: int) -> dict[str, set[int]]:
        """NPCs, objects and items a quest record points at (for the zone tables)."""
        info = self.quests[qid]
        npcs = {i for k, i in (*info.starters, *info.finishers) if k == "n"}
        objects = {i for k, i in (*info.starters, *info.finishers) if k == "o"}
        items = {i for k, i in info.starters if k == "i"}
        items.update(r["i"] for r in self.ctx.rewards(qid))
        for obj in self.ctx.objectives(qid):
            if obj["k"] == "c" and "i" in obj:
                npcs.add(int(obj["i"]))
            elif obj["k"] == "o" and "i" in obj:
                objects.add(int(obj["i"]))
            elif obj["k"] == "i" and "i" in obj:
                items.add(int(obj["i"]))
                npcs.update(int(s[0]) for s in obj.get("src", []))
        return {"npcs": npcs, "objects": objects, "items": items}
