"""Shared lookups for the shape step: quest filtering, entity positions, objectives, rewards."""

from __future__ import annotations

import re
import statistics
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from typing import Any

from pipeline.shape import flags as flagmod
from pipeline.shape.coords import ZPoint, cluster_spawns, valid_spawns
from pipeline.shape.data import RawData
from pipeline.shape.factions import FactionConfig

Ref = tuple[str, int]  # ("n" | "o" | "i", id): npc, object, item

# Item classes
ITEM_CONTAINER = 1
ITEM_WEAPON = 2
ITEM_ARMOR = 4
UPGRADE_MARGIN = 2  # itemLevel must beat the level baseline by this much

# Item-objective source filtering: with more than this many source NPCs, only mobs whose level
# range overlaps [questLevel - 4, questLevel + 3] are used for the cluster centres.
MAX_UNFILTERED_SOURCES = 8
SOURCE_LEVEL_BELOW = 4
SOURCE_LEVEL_ABOVE = 3
MAX_SOURCE_LIST = 3
MAX_TEXT_CHARS = 240

_EXPLORE_KINDS = {"monster": "c", "object": "o", "item": "i"}


@dataclass
class QuestInfo:
    """A quest that passed the faction filters, with derived placement data."""

    id: int
    raw: dict[str, Any]
    level: int  # effective level used for band membership
    races: tuple[str, ...] | None  # None = open to every faction race
    starters: list[Ref]
    finishers: list[Ref]
    start_zone: int | None = None
    finish_zone: int | None = None
    zone: int | None = None  # primary zone
    classes: list[str] = field(default_factory=list)


@dataclass
class FilterStats:
    total: int = 0
    placeholder: int = 0
    wrong_faction: int = 0
    hostile_starters: int = 0
    no_starter: int = 0
    no_starter_all_db: int = 0
    kept: int = 0
    class_quests: int = 0
    unusual_race_bits: dict[int, int] = field(default_factory=dict)
    unknown_class_bits: dict[int, int] = field(default_factory=dict)


def refs(giver: dict[str, Any] | None) -> list[Ref]:
    giver = giver or {}
    out: list[Ref] = []
    for kind, key in (("n", "npcs"), ("o", "objects"), ("i", "items")):
        for ident in giver.get(key) or []:
            out.append((kind, int(ident)))
    return out


def race_restriction(mask: int, cfg: FactionConfig) -> tuple[str, ...] | None:
    """Which faction races a quest is limited to, or ``None`` if it is open to all of them."""
    names = tuple(sorted(r for r, bit in cfg.race_bits.items() if mask & bit))
    if not names or len(names) == len(cfg.race_bits):
        return None
    return names


def race_available(mask: int, cfg: FactionConfig) -> bool:
    """Faction filter (PRD §5.1). ``0`` is open to everyone; otherwise a race bit or the faction
    flag (bit 33 for Horde) must be set. The other faction's flag alone does not qualify."""
    return mask == 0 or bool(mask & (cfg.race_mask | cfg.faction_flag))


def effective_level(quest: dict[str, Any]) -> int:
    """questLevel, or requiredLevel (min 1) for the few quests with level -1 / 0 (they scale)."""
    ql = int(quest.get("questLevel", 0))
    if ql > 0:
        return ql
    return max(int(quest.get("requiredLevel", 0)), 1)


def in_band(level: int, lo: int, hi: int, overlap: int = 2) -> bool:
    """PRD §5.3 / prompt: a quest is in a band pack if ``lo - overlap <= level <= hi + overlap``."""
    return lo - overlap <= level <= hi + overlap


class ShapeContext:
    def __init__(self, raw: RawData, cfg: FactionConfig) -> None:
        self.raw = raw
        self.cfg = cfg
        self._points: dict[Ref, list[ZPoint]] = {}
        self._objectives: dict[int, list[dict[str, Any]]] = {}
        self._rewards: dict[int, list[dict[str, Any]]] = {}
        self._baseline: dict[int, int] | None = None
        self._chain_value: dict[int, bool] = {}
        self.quests: dict[int, QuestInfo] = {}
        self.stats = FilterStats()
        self._service_npcs: list[tuple[str, int, float, float, int, str]] | None = None

    # ---- names -------------------------------------------------------------------------

    def entity_name(self, ref: Ref) -> str:
        kind, ident = ref
        table = {"n": self.raw.npcs, "o": self.raw.objects, "i": self.raw.items}[kind]
        return str(table.get(ident, {}).get("name", ""))

    def zone_name(self, zone: int) -> str:
        return self.raw.zone_name(zone)

    # ---- positions ---------------------------------------------------------------------

    def npc_friendly_to(self, npc_id: int) -> str | None:
        return self.raw.npcs.get(npc_id, {}).get("friendlyToFaction")

    def entity_points(self, ref: Ref) -> list[ZPoint]:
        """Valid spawn points of an NPC or object. Item givers resolve through their drop
        sources (no points if the source has none)."""
        if ref in self._points:
            return self._points[ref]
        kind, ident = ref
        if kind == "n":
            pts = valid_spawns(self.raw.npcs.get(ident, {}).get("spawns"))
        elif kind == "o":
            pts = valid_spawns(self.raw.objects.get(ident, {}).get("spawns"))
        else:
            pts = sorted(
                {p for n in self.item_sources(ident)[0] for p in self.entity_points(("n", n))}
            )
        self._points[ref] = pts
        return pts

    def item_sources(self, item_id: int) -> tuple[list[int], list[int]]:
        item = self.raw.items.get(item_id, {})
        npcs = [n for n in item.get("npcDrops") or [] if n in self.raw.npcs]
        objs = [o for o in item.get("objectDrops") or [] if o in self.raw.objects]
        return sorted(set(npcs)), sorted(set(objs))

    @staticmethod
    def _main_zone(points: list[ZPoint]) -> int | None:
        if not points:
            return None
        counts = Counter(p[0] for p in points)
        return sorted(counts, key=lambda z: (-counts[z], z))[0]

    # ---- quest filtering ---------------------------------------------------------------

    def build_quests(self) -> None:
        cfg, raw, st = self.cfg, self.raw, self.stats
        st.total = len(raw.quests)
        unusual: Counter[int] = Counter()
        unknown_cls: Counter[int] = Counter()
        known_bits = set(cfg.race_bits.values()) | {cfg.faction_flag, cfg.other_faction_flag}
        known_all = 0
        for bit in known_bits:
            known_all |= bit
        # The DB often leaves startedBy empty and links the starting item the other way round
        # (items.startQuest, or the quest's sourceItemId). Those items are kind-"i" starters.
        item_starters: dict[int, list[int]] = {}
        for item_id, item in raw.items.items():
            if item.get("startQuest"):
                item_starters.setdefault(int(item["startQuest"]), []).append(item_id)
        for qid in sorted(raw.quests):
            quest = raw.quests[qid]
            starters = refs(quest.get("startedBy"))
            if not starters:
                source = int(quest.get("sourceItemId") or 0)
                ids = item_starters.get(qid) or ([source] if source in raw.items else [])
                starters = [("i", i) for i in sorted(ids)]
            if not starters:
                st.no_starter_all_db += 1
            if quest.get("placeholder"):
                st.placeholder += 1
                continue
            mask = int(quest.get("requiredRaces", 0))
            if mask & ~known_all:
                # Bits we do not know (Alliance races etc. are expected; count the rest).
                other_races = 0
                for bit in (1, 4, 8, 64):  # Human, Dwarf, Night Elf, Gnome
                    other_races |= bit
                extra = mask & ~known_all & ~other_races
                if extra:
                    unusual[extra] += 1
            if not race_available(mask, cfg):
                st.wrong_faction += 1
                continue
            npc_starters = [r for r in starters if r[0] == "n"]
            if (
                starters
                and len(npc_starters) == len(starters)
                and all(self.npc_friendly_to(i) == cfg.opposing_code for _, i in npc_starters)
            ):
                st.hostile_starters += 1
                continue
            if not starters:
                st.no_starter += 1
                continue
            cmask = int(quest.get("requiredClasses", 0))
            tokens = flagmod.class_tokens(cmask) if cmask else []
            for tok in tokens:
                if tok.startswith("BIT"):
                    unknown_cls[int(tok[3:])] += 1
            if tokens:
                st.class_quests += 1
            info = QuestInfo(
                id=qid,
                raw=quest,
                level=effective_level(quest),
                races=race_restriction(mask, cfg),
                starters=starters,
                finishers=refs(quest.get("finishedBy")),
                classes=tokens,
            )
            self._place(info)
            self.quests[qid] = info
        st.kept = len(self.quests)
        st.unusual_race_bits = dict(sorted(unusual.items()))
        st.unknown_class_bits = dict(sorted(unknown_cls.items()))

    def _place(self, info: QuestInfo) -> None:
        for refs_, attr in ((info.starters, "start_zone"), (info.finishers, "finish_zone")):
            for ref in refs_:
                zone = self._main_zone(self.entity_points(ref))
                if zone is not None:
                    setattr(info, attr, zone)
                    break
        zone = info.start_zone or info.finish_zone
        if zone is None:
            zos = int(info.raw.get("zoneOrSort", 0))
            if zos > 0:
                zone = zos
        if zone is None:
            for obj in self.objectives(info.id):
                if obj.get("c"):
                    zone = obj["c"][0]["z"]
                    break
        info.zone = zone

    # ---- objectives --------------------------------------------------------------------

    def objectives(self, qid: int) -> list[dict[str, Any]]:
        if qid in self._objectives:
            return self._objectives[qid]
        quest = self.raw.quests[qid]
        ql = effective_level(quest)
        out: list[dict[str, Any]] = []
        obj = quest.get("objectives") or {}
        for entry in obj.get("creature") or []:
            out.append(self._creature_objective(int(entry[0]), "c"))
        for entry in obj.get("object") or []:
            out.append(self._object_objective(int(entry[0]), entry[1] if len(entry) > 1 else None))
        for entry in obj.get("item") or []:
            out.append(self._item_objective(int(entry[0]), quest, ql))
        trigger = quest.get("triggerEnd")
        if trigger:
            out.append(self._trigger_objective(trigger))
        for extra in quest.get("extraObjectives") or []:
            out.extend(self._extra_objective(extra, quest, ql))
        self._objectives[qid] = out
        return out

    def _npc_info(self, npc_id: int) -> dict[str, Any]:
        npc = self.raw.npcs.get(npc_id, {})
        return {
            "lv": [int(npc.get("minLevel", 0)), int(npc.get("maxLevel", 0))],
            "rk": int(npc.get("rank", 0)),
        }

    def _creature_objective(self, npc_id: int, kind: str) -> dict[str, Any]:
        entry = {"k": kind, "i": npc_id, "n": self.entity_name(("n", npc_id))}
        entry.update(self._npc_info(npc_id))
        self._add_clusters(entry, self.entity_points(("n", npc_id)))
        return entry

    def _object_objective(self, obj_id: int, text: Any = None) -> dict[str, Any]:
        entry: dict[str, Any] = {"k": "o", "i": obj_id, "n": self.entity_name(("o", obj_id))}
        if isinstance(text, str) and text:
            entry["t"] = text
        self._add_clusters(entry, self.entity_points(("o", obj_id)))
        return entry

    def _item_objective(self, item_id: int, quest: dict[str, Any], ql: int) -> dict[str, Any]:
        entry: dict[str, Any] = {"k": "i", "i": item_id, "n": self.entity_name(("i", item_id))}
        npcs, objs = self.item_sources(item_id)
        kept = self._filter_sources(npcs, ql)
        if kept:
            infos = [self._npc_info(n) for n in kept]
            entry["lv"] = [min(i["lv"][0] for i in infos), max(i["lv"][1] for i in infos)]
            # Rank of the easiest source: if even that is elite the objective is elite.
            entry["rk"] = min(i["rk"] for i in infos)
            counts = {n: len(self.entity_points(("n", n))) for n in kept}
            top = sorted(kept, key=lambda n: (-counts[n], n))[:MAX_SOURCE_LIST]
            entry["src"] = [[n, self.entity_name(("n", n))] for n in top]
        if len(npcs) + len(objs) > len(kept):
            entry["ns"] = len(npcs) + len(objs)
        points = [p for n in kept for p in self.entity_points(("n", n))]
        points += [p for o in objs for p in self.entity_points(("o", o))]
        self._add_clusters(entry, points)
        return entry

    def _filter_sources(self, npcs: list[int], ql: int) -> list[int]:
        npcs = [n for n in npcs if self.entity_points(("n", n))]
        if len(npcs) <= MAX_UNFILTERED_SOURCES:
            return npcs
        lo, hi = ql - SOURCE_LEVEL_BELOW, ql + SOURCE_LEVEL_ABOVE
        near = [
            n
            for n in npcs
            if self.raw.npcs[n].get("maxLevel", 0) >= lo
            and self.raw.npcs[n].get("minLevel", 0) <= hi
        ]
        return near or npcs

    def _trigger_objective(self, trigger: Any) -> dict[str, Any]:
        entry: dict[str, Any] = {"k": "t"}
        if isinstance(trigger, list) and trigger:
            if isinstance(trigger[0], str):
                entry["t"] = trigger[0]
            spawns = trigger[1] if len(trigger) > 1 and isinstance(trigger[1], dict) else {}
            self._add_clusters(entry, valid_spawns(spawns))
        return entry

    def _extra_objective(self, extra: Any, quest: dict[str, Any], ql: int) -> list[dict[str, Any]]:
        """``extraObjectives`` rows: ``[?, ?, text, ?, [[kind, id], ...]]``."""
        out: list[dict[str, Any]] = []
        if not isinstance(extra, list) or len(extra) < 5:
            return out
        text = extra[2] if isinstance(extra[2], str) else ""
        for ref in extra[4] or []:
            if not (isinstance(ref, list) and len(ref) == 2):
                continue
            kind, ident = _EXPLORE_KINDS.get(ref[0]), int(ref[1])
            if kind == "c":
                entry = self._creature_objective(ident, "c")
            elif kind == "o":
                entry = self._object_objective(ident)
            elif kind == "i":
                entry = self._item_objective(ident, quest, ql)
            else:
                continue
            if text:
                entry["t"] = text
            entry["x"] = 1  # came from extraObjectives
            out.append(entry)
        return out

    def _add_clusters(self, entry: dict[str, Any], points: list[ZPoint]) -> None:
        clusters, total = cluster_spawns(points)
        if clusters:
            entry["c"] = [c.to_json() for c in clusters]
            entry["sp"] = total

    def objective_ranks(self, qid: int) -> list[int]:
        """Ranks that count toward elite/group: direct creatures, and item sources (easiest)."""
        return [o["rk"] for o in self.objectives(qid) if "rk" in o]

    def objective_zones(self, qid: int) -> set[int]:
        return {c["z"] for o in self.objectives(qid) for c in o.get("c", [])}

    # ---- rewards -----------------------------------------------------------------------

    def _level_baseline(self) -> dict[int, int]:
        """Median weapon/armor reward itemLevel per quest level (smoothed over +-2 levels)."""
        by_level: dict[int, list[int]] = defaultdict(list)
        for quest in self.raw.quests.values():
            lvl = effective_level(quest)
            for iid in quest.get("rewardItemIds") or []:
                item = self.raw.items.get(iid)
                if item and item.get("class") in (ITEM_WEAPON, ITEM_ARMOR) and item["itemLevel"]:
                    by_level[lvl].append(int(item["itemLevel"]))
        baseline: dict[int, int] = {}
        for lvl in range(1, 71):
            window = [v for d in range(-2, 3) for v in by_level.get(lvl + d, [])]
            baseline[lvl] = int(statistics.median_low(window)) if window else lvl
        return baseline

    def rewards(self, qid: int) -> list[dict[str, Any]]:
        if qid in self._rewards:
            return self._rewards[qid]
        if self._baseline is None:
            self._baseline = self._level_baseline()
        quest = self.raw.quests[qid]
        base = self._baseline.get(min(max(effective_level(quest), 1), 70), 0)
        out: list[dict[str, Any]] = []
        for iid in sorted(set(quest.get("rewardItemIds") or [])):
            item = self.raw.items.get(iid)
            if not item:
                continue
            entry: dict[str, Any] = {
                "i": iid,
                "n": item.get("name", ""),
                "c": item["class"],
                "s": item["subClass"],
                "il": item["itemLevel"],
                "rl": item["requiredLevel"],
            }
            if item["class"] == ITEM_CONTAINER:
                entry["bag"] = 1
            if (
                item["class"] in (ITEM_WEAPON, ITEM_ARMOR)
                and item["itemLevel"] >= base + UPGRADE_MARGIN
            ):
                entry["up"] = 1
            out.append(entry)
        self._rewards[qid] = out
        return out

    def chain_has_value(self, qid: int) -> bool:
        """True if the quest or anything down its chain rewards a bag or an upgrade."""
        if qid in self._chain_value:
            return self._chain_value[qid]
        members = flagmod.chain_members(self.raw.quests, qid)
        valuable = any(r.get("bag") or r.get("up") for m in members for r in self.rewards(m))
        self._chain_value[qid] = valuable
        return valuable

    # ---- flags -------------------------------------------------------------------------

    def quest_flags(self, info: QuestInfo) -> list[str]:
        quest, qid = info.raw, info.id
        ranks = self.objective_ranks(qid)
        zones = self.objective_zones(qid)
        out: list[str] = []
        if any(r in flagmod.ELITE_RANKS for r in ranks):
            out.append("elite")
        if flagmod.is_group(quest, ranks):
            out.append("group")
        if flagmod.is_escort(quest):
            out.append("escort")
        zos = int(quest.get("zoneOrSort", 0))
        if zones & self.raw.dungeon_ids or zos in self.raw.dungeon_ids:
            out.append("dungeon")
        if quest.get("requiredSkill"):
            out.append("profession")
        if quest.get("requiredMinRep"):
            out.append("rep")
        if quest.get("breadcrumbForQuestId"):
            out.append("breadcrumb")
        has_next = quest.get("nextQuestInChain") or quest.get("childQuests")
        if has_next and not flagmod.has_prereqs(quest) and self.chain_has_value(qid):
            out.append("chainHead")
        out.extend(f"class:{c}" for c in info.classes)
        return out

    # ---- services (innkeepers, flight masters ...) --------------------------------------

    def service_npcs(self) -> list[tuple[str, int, float, float, int, str]]:
        """Friendly-to-faction service NPCs: ``(tag, zone, x, y, npcId, name)``."""
        if self._service_npcs is not None:
            return self._service_npcs
        fm = set(self.cfg.flight_master_subnames)
        out: list[tuple[str, int, float, float, int, str]] = []
        for nid in sorted(self.raw.npcs):
            npc = self.raw.npcs[nid]
            sub = npc.get("subName")
            if not sub or self.cfg.own_code not in (npc.get("friendlyToFaction") or ""):
                continue
            tag = None
            if sub == "Innkeeper":
                tag = "inn"
            elif sub in fm:
                tag = "fm"
            elif sub == "Zeppelin Master":
                tag = "zep"
            elif sub == "Stable Master":
                tag = "stable"
            if not tag:
                continue
            pts = valid_spawns(npc.get("spawns"))
            if pts:
                z, x, y = pts[0]
                out.append((tag, z, x, y, nid, npc.get("name", "")))
        self._service_npcs = out
        return out


_TEXT_WS = re.compile(r"\s+")


def objective_text(quest: dict[str, Any]) -> str:
    text = _TEXT_WS.sub(" ", " ".join(quest.get("objectivesText") or [])).strip()
    if len(text) > MAX_TEXT_CHARS:
        text = text[: MAX_TEXT_CHARS - 1].rstrip() + "…"
    return text
