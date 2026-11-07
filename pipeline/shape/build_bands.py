"""Build the band packs: tracks, hubs, quest entries, size guard, writers."""

from __future__ import annotations

import json
import math
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from pipeline.shape.context import (
    QuestInfo,
    Ref,
    ShapeContext,
    in_band,
    objective_text,
)
from pipeline.shape.coords import (
    HUB_JOIN_RADIUS,
    Hub,
    ZPoint,
    dist,
    find_hubs,
    nearest_hub,
    pick_spawn,
    r1,
)
from pipeline.shape.factions import FactionConfig
from pipeline.shape.places import settlement_name
from pipeline.shape.xp_table import xp_for_levels

CHARS_PER_TOKEN = 4
PACK_TOKEN_LIMIT = 40_000
# Packs are cut a little below the hard limit so a rebuild after splitting still fits.
SPLIT_TARGET_FRACTION = 0.85
HEADER_OVERHEAD_CHARS = 8_000
SERVICE_RADIUS = 6.0

KEYS_DOC: dict[str, str] = {
    "band": "[lo, hi] level range of the pack",
    "branch": "track: durotar | mulgore | tirisfal | horde (shared)",
    "hubs": "h = index+1 used by quest entities. n quests, svc = inn/fm/zep/stable nearby",
    "id": "route id this pack feeds: <faction>_<track>_<lo>-<hi>[part]",
    "part": "sub-region letter if the band was cut for size, with the zones in `zones`",
    "xpBudget": "XP needed to climb lo -> hi (Classic table); aim for 110-130% in the route",
    "zones": "i = zone id, n = name, q = quests starting there, lv = [min, max] quest level",
    "quests.i": "quest id",
    "quests.n": "name",
    "quests.l": "questLevel (requiredLevel/1 if the DB says scaling)",
    "quests.rl": "requiredLevel",
    "quests.xp": "XP reward at questLevel (xpDB-classic), absent if unknown",
    "quests.z": "primary zone id (starter zone, else finisher, else zoneOrSort)",
    "quests.s": "starter entity {k: n|o|i npc/object/item, i, n, z, x, y, h hub}",
    "quests.sa": "up to 2 alternative starters as [k, i, n, z, x, y]",
    "quests.f": "finisher entity, same shape as s; the string 's' means same entity as the starter",
    "quests.fa": "alternative finishers, like sa",
    "quests.o": (
        "objectives: k c creature | o object | i item | t explore trigger, x=1 from "
        "extraObjectives; i id, n name, t text, lv [minLevel, maxLevel], rk rank "
        "(0 normal 1 elite 2 rare-elite 3 boss 4 rare; for items = easiest source), "
        "c up to 2 clusters {z zone, x, y, r radius, n spawns}, sp total spawns, "
        "src top drop sources [npc, name], ns total drop sources if more were considered"
    ),
    "quests.t": "objective text from the DB (truncated)",
    "quests.fl": (
        "flags: elite group escort dungeon profession rep breadcrumb chainHead class:<TOKEN>"
    ),
    "quests.rw": (
        "reward items: i, n, c item class, s subClass, il itemLevel, rl requiredLevel, "
        "up=1 upgradeCandidate (weapon/armor above the level baseline), bag=1 container"
    ),
    "quests.pa": "preQuestGroup: all of these must be turned in first",
    "quests.ps": "preQuestSingle: any one of these",
    "quests.nx": "nextQuestInChain",
    "quests.ch": "childQuests",
    "quests.ex": "exclusiveTo: quests that lock this one out",
    "quests.bc": "breadcrumbForQuestId",
    "quests.r": "races the quest is limited to (absent = all faction races)",
    "quests.sk": "requiredSkill [skill, value]",
    "quests.rp": "requiredMinRep [faction, value]",
    "quests.si": "sourceItemId (item given on accept)",
    "quests.of": "objective-first hint from Forever: item | killCredit",
}


class PackTooLarge(Exception):
    """A single unsplittable chunk is over the token limit."""


@dataclass
class PackResult:
    pack: dict[str, Any]
    text: str
    tokens: int


@dataclass
class TrackPlan:
    quests: dict[str, list[int]] = field(default_factory=dict)
    orphans: list[int] = field(default_factory=list)
    note: str = ""


def estimate_tokens(text: str) -> int:
    return math.ceil(len(text) / CHARS_PER_TOKEN)


def band_label(lo: int, hi: int) -> str:
    return f"{lo:02d}-{hi:02d}"


def all_bands(cfg: FactionConfig) -> list[tuple[int, int]]:
    first, top = cfg.levels
    width = cfg.band_width
    return [(first, width), *((s, s + width) for s in range(width, top, width))]


# ---- tracks -------------------------------------------------------------------------------


def _races_overlap(info: QuestInfo, races: Sequence[str]) -> bool:
    return info.races is None or bool(set(info.races) & set(races))


def plan_tracks(ctx: ShapeContext, lo: int, hi: int) -> TrackPlan:
    cfg, raw = ctx.cfg, ctx.raw
    window = [i for i in ctx.quests.values() if in_band(i.level, lo, hi, cfg.overlap)]
    window.sort(key=lambda i: i.id)
    plan = TrackPlan()

    if (lo, hi) in cfg.split_bands:
        for b in cfg.branches:
            plan.quests[b.id] = []
        for info in window:
            placed = False
            for b in cfg.branches:
                if not _races_overlap(info, b.races):
                    continue
                home = {raw.zone_id(z) for z in b.home_zones}
                region = set(home)
                if lo >= b.reach_from_level:
                    region |= {raw.zone_id(z) for z in b.reach_zones}
                sz = info.start_zone or info.zone
                if (sz in region) or (info.finish_zone in home):
                    plan.quests[b.id].append(info.id)
                    placed = True
            if not placed:
                plan.orphans.append(info.id)
        plan.note = "split per start branch"
        return plan

    if (lo, hi) in cfg.detect_split_bands:
        late_zones = {raw.zone_id(z) for z in cfg.late_split_zones}
        late_branch = cfg.branch(cfg.late_split_branch)
        late, rest = [], []
        for info in window:
            in_zone = (info.start_zone or info.zone) in late_zones or info.finish_zone in late_zones
            only_late = info.races is not None and set(info.races) <= set(late_branch.races)
            if (in_zone and _races_overlap(info, late_branch.races)) or only_late:
                late.append(info.id)
            elif _races_overlap(info, [r for r in cfg.race_bits if r not in late_branch.races]):
                rest.append(info.id)
            else:
                plan.orphans.append(info.id)
        if len(late) >= cfg.late_split_min_quests and len(rest) >= cfg.late_split_min_quests:
            plan.quests[late_branch.id] = late
            plan.quests[cfg.shared_track] = rest
            plan.note = (
                f"split: {len(late)} quests in {'/'.join(cfg.late_split_zones)} vs "
                f"{len(rest)} elsewhere (threshold {cfg.late_split_min_quests} each)"
            )
        else:
            plan.quests[cfg.shared_track] = [i.id for i in window]
            plan.orphans = []
            plan.note = (
                f"not split: {len(late)} late-region vs {len(rest)} other quests "
                f"(threshold {cfg.late_split_min_quests} each)"
            )
        return plan

    plan.quests[cfg.shared_track] = [i.id for i in window]
    plan.note = "shared"
    return plan


# ---- pack assembly ------------------------------------------------------------------------


def _entity_json(
    ctx: ShapeContext, ref: Ref, point: ZPoint | None, hub: int | None
) -> dict[str, Any]:
    out: dict[str, Any] = {"k": ref[0], "i": ref[1], "n": ctx.entity_name(ref)}
    if point:
        out.update({"z": point[0], "x": r1(point[1]), "y": r1(point[2])})
    if hub is not None:
        out["h"] = hub + 1
    return out


def _alt_json(e: dict[str, Any]) -> list[Any]:
    return [e["k"], e["i"], e["n"], e.get("z"), e.get("x"), e.get("y")]


def _pick_primary(
    refs_: list[Ref], chosen: dict[Ref, ZPoint | None], hubs: list[Hub]
) -> tuple[Ref, list[Ref]]:
    def key(ref: Ref) -> tuple[int, float, int]:
        pt = chosen.get(ref)
        if pt is None:
            return (2, 0.0, ref[1])
        idx = nearest_hub(hubs, pt, HUB_JOIN_RADIUS)
        if idx is None:
            return (1, 0.0, ref[1])
        return (0, dist((hubs[idx].x, hubs[idx].y), (pt[1], pt[2])), ref[1])

    ordered = sorted(refs_, key=key)
    return ordered[0], ordered[1:3]


def _hub_name(ctx: ShapeContext, hub: Hub) -> str:
    name = settlement_name(ctx.cfg.id, ctx.raw.zone_by_name, hub.zone, hub.x, hub.y)
    if name:
        return name
    return f"{ctx.zone_name(hub.zone)} ({hub.x:.0f}, {hub.y:.0f})"


def _hub_services(ctx: ShapeContext, hub: Hub) -> list[str]:
    tags = {
        tag
        for tag, z, x, y, _nid, _name in ctx.service_npcs()
        if z == hub.zone and dist((x, y), (hub.x, hub.y)) <= SERVICE_RADIUS
    }
    return sorted(tags)


def build_quest_entries(
    ctx: ShapeContext, infos: list[QuestInfo]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Return ``(quest entries, hubs)`` for a set of quests; hubs are derived from them."""
    refs_all: list[Ref] = sorted(
        {r for i in infos for r in (*i.starters, *i.finishers)},
        key=lambda r: (r[0], r[1]),
    )
    cands = {r: ctx.entity_points(r) for r in refs_all}
    anchors = {pts[0] for pts in cands.values() if len(pts) == 1}
    hubs0 = find_hubs(anchors)
    chosen: dict[Ref, ZPoint | None] = {}
    for ref in refs_all:
        pts = cands[ref]
        if not pts:
            chosen[ref] = None
        elif len(pts) == 1:
            chosen[ref] = pts[0]
        else:
            chosen[ref] = pick_spawn(pts, hubs0)
    hubs = find_hubs({p for p in chosen.values() if p})
    hub_of = {r: (nearest_hub(hubs, p, HUB_JOIN_RADIUS) if p else None) for r, p in chosen.items()}

    hub_counts: Counter[int] = Counter()
    entries: list[dict[str, Any]] = []
    for info in infos:
        quest = info.raw
        s_ref, s_alt = _pick_primary(info.starters, chosen, hubs)
        s = _entity_json(ctx, s_ref, chosen.get(s_ref), hub_of.get(s_ref))
        entry: dict[str, Any] = {
            "i": info.id,
            "n": quest.get("name", ""),
            "l": info.level,
            "s": s,
        }
        if quest.get("requiredLevel"):
            entry["rl"] = int(quest["requiredLevel"])
        if info.id in ctx.raw.xp:
            entry["xp"] = ctx.raw.xp[info.id][1]
        if info.zone is not None:
            entry["z"] = info.zone
        if s_alt:
            entry["sa"] = [_alt_json(_entity_json(ctx, r, chosen.get(r), None)) for r in s_alt]
        hubs_used = {hub_of.get(s_ref)}
        if info.finishers:
            f_ref, f_alt = _pick_primary(info.finishers, chosen, hubs)
            if f_ref == s_ref:
                entry["f"] = "s"
            else:
                entry["f"] = _entity_json(ctx, f_ref, chosen.get(f_ref), hub_of.get(f_ref))
            hubs_used.add(hub_of.get(f_ref))
            if f_alt:
                entry["fa"] = [_alt_json(_entity_json(ctx, r, chosen.get(r), None)) for r in f_alt]
        for h in hubs_used:
            if h is not None:
                hub_counts[h] += 1
        objs = ctx.objectives(info.id)
        if objs:
            entry["o"] = objs
        text = objective_text(quest)
        if text:
            entry["t"] = text
        flags = ctx.quest_flags(info)
        if flags:
            entry["fl"] = flags
        rewards = ctx.rewards(info.id)
        if rewards:
            entry["rw"] = rewards
        for key, field_name in (
            ("pa", "preQuestGroup"),
            ("ps", "preQuestSingle"),
            ("ch", "childQuests"),
            ("ex", "exclusiveTo"),
        ):
            val = quest.get(field_name)
            if val:
                entry[key] = sorted(val)
        if quest.get("nextQuestInChain"):
            entry["nx"] = quest["nextQuestInChain"]
        if quest.get("breadcrumbForQuestId"):
            entry["bc"] = quest["breadcrumbForQuestId"]
        if info.races:
            entry["r"] = list(info.races)
        if quest.get("requiredSkill"):
            entry["sk"] = quest["requiredSkill"]
        if quest.get("requiredMinRep"):
            entry["rp"] = quest["requiredMinRep"]
        if quest.get("sourceItemId"):
            entry["si"] = quest["sourceItemId"]
        for hint_key, label in (
            ("itemObjectiveFirst", "item"),
            ("killCreditObjectiveFirst", "killCredit"),
        ):
            if info.id in ctx.raw.objective_hints.get(hint_key, []):
                entry["of"] = label
        entries.append(entry)

    hub_json = []
    for idx, hub in enumerate(hubs):
        item: dict[str, Any] = {
            "h": idx + 1,
            "name": _hub_name(ctx, hub),
            "z": hub.zone,
            "x": r1(hub.x),
            "y": r1(hub.y),
            "n": hub_counts.get(idx, 0),
        }
        svc = _hub_services(ctx, hub)
        if svc:
            item["svc"] = svc
        hub_json.append(item)
    return entries, hub_json


def build_pack(
    ctx: ShapeContext, track: str, lo: int, hi: int, qids: list[int], part: str | None
) -> PackResult:
    cfg, raw = ctx.cfg, ctx.raw
    infos = [ctx.quests[q] for q in sorted(qids)]
    entries, hubs = build_quest_entries(ctx, infos)
    zone_stats: dict[int, list[int]] = {}
    for info in infos:
        if info.zone is not None:
            zone_stats.setdefault(info.zone, []).append(info.level)
    zones = [
        {"i": z, "n": ctx.zone_name(z), "q": len(v), "lv": [min(v), max(v)]}
        for z, v in sorted(zone_stats.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    ]
    label = band_label(lo, hi) + (part or "")
    q = raw.manifest.get("questiedb", {})
    pack: dict[str, Any] = {
        "_keys": KEYS_DOC,
        "band": [lo, hi],
        "branch": track,
        "db": {"buildCommit": q.get("build_commit"), "questieDbVersion": q.get("version")},
        "faction": cfg.id,
        "hubs": hubs,
        "id": f"{cfg.id}_{track}_{label}",
        "quests": entries,
        "xpBudget": xp_for_levels(lo, hi),
        "zones": zones,
    }
    if part:
        pack["part"] = part
    text = dump_pack(pack)
    return PackResult(pack, text, estimate_tokens(text))


def dump_pack(pack: dict[str, Any]) -> str:
    """Deterministic JSON: sorted keys, one quest per line, everything else compact."""

    def compact(value: Any) -> str:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

    lines = ["{"]
    keys = sorted(pack)
    for n, key in enumerate(keys):
        comma = "," if n < len(keys) - 1 else ""
        if key == "quests":
            lines.append('"quests":[')
            quests = pack["quests"]
            for qi, entry in enumerate(quests):
                lines.append(compact(entry) + ("," if qi < len(quests) - 1 else ""))
            lines.append("]" + comma)
        elif key == "hubs":
            lines.append('"hubs":[')
            hubs = pack["hubs"]
            for hi_, entry in enumerate(hubs):
                lines.append(compact(entry) + ("," if hi_ < len(hubs) - 1 else ""))
            lines.append("]" + comma)
        else:
            lines.append(f'"{key}":{compact(pack[key])}{comma}')
    lines.append("}")
    return "\n".join(lines) + "\n"


# ---- size guard ---------------------------------------------------------------------------


def check_pack_size(text: str, limit: int = PACK_TOKEN_LIMIT) -> int:
    """Raise if the pack is over the token budget. Returns the estimate."""
    tokens = estimate_tokens(text)
    if tokens > limit:
        raise PackTooLarge(f"pack is ~{tokens} tokens, limit {limit}")
    return tokens


def split_ids(
    groups: list[list[tuple[int, int]]], limit_chars: int, overhead: int = HEADER_OVERHEAD_CHARS
) -> list[list[int]]:
    """Group zone-ordered ``[(qid, size_chars), ...]`` lists into parts under ``limit_chars``.

    ``groups`` is one list per zone, already in geographic order. Whole zones stay together
    when they fit; an oversized zone is chunked in the order given. Never drops a quest.
    """
    budget = max(limit_chars - overhead, 1)
    total = sum(s for g in groups for _, s in g)
    parts_needed = max(1, math.ceil(total / budget))
    ideal = total / parts_needed
    parts: list[list[int]] = []
    cur: list[int] = []
    cur_size = 0

    def flush() -> None:
        nonlocal cur, cur_size
        if cur:
            parts.append(cur)
        cur, cur_size = [], 0

    for group in groups:
        gsize = sum(s for _, s in group)
        if gsize > budget:
            flush()
            for qid, size in group:
                if cur_size + size > budget:
                    flush()
                cur.append(qid)
                cur_size += size
            flush()
            continue
        if cur and (cur_size + gsize > budget or cur_size >= ideal):
            flush()
        cur.extend(q for q, _ in group)
        cur_size += gsize
    flush()
    # A small trailing remainder is folded back into the previous part when it still fits.
    hard = max(int(limit_chars / SPLIT_TARGET_FRACTION * 0.95) - overhead, budget)
    sizes = {q: s for g in groups for q, s in g}
    while len(parts) > 1:
        last, prev = sum(sizes[q] for q in parts[-1]), sum(sizes[q] for q in parts[-2])
        if last < 0.3 * ideal and prev + last <= hard:
            parts[-2].extend(parts.pop())
        else:
            break
    return parts


def build_packs_for_track(
    ctx: ShapeContext,
    track: str,
    lo: int,
    hi: int,
    qids: list[int],
    limit: int = PACK_TOKEN_LIMIT,
) -> list[PackResult]:
    """Build the pack for a track, cutting it into sub-region parts (a, b, ...) if needed."""
    full = build_pack(ctx, track, lo, hi, qids, None)
    if full.tokens <= limit:
        return [full]
    order = {name: n for n, name in enumerate(ctx.cfg.zone_order)}
    entry_size = {
        e["i"]: len(json.dumps(e, separators=(",", ":"))) + 1 for e in full.pack["quests"]
    }

    def zone_key(qid: int) -> tuple[int, int]:
        zone = ctx.quests[qid].zone
        name = ctx.raw.zone_by_id.get(zone) if zone is not None else None
        return (order.get(name, len(order)) if name else len(order) + 1, zone or 0)

    return _split_recursive(ctx, track, lo, hi, qids, entry_size, zone_key, limit)


def _split_recursive(
    ctx: ShapeContext,
    track: str,
    lo: int,
    hi: int,
    qids: list[int],
    entry_size: dict[int, int],
    zone_key: Any,
    limit: int,
) -> list[PackResult]:
    by_zone: dict[tuple[int, int], list[int]] = {}
    for q in sorted(qids):
        by_zone.setdefault(zone_key(q), []).append(q)
    groups = [[(q, entry_size[q]) for q in by_zone[k]] for k in sorted(by_zone)]
    limit_chars = int(limit * CHARS_PER_TOKEN * SPLIT_TARGET_FRACTION)
    parts = split_ids(groups, limit_chars)
    results: list[PackResult] = []
    letters = "abcdefghij"
    if len(parts) < 2:  # estimate said fits, but the real build did not: force a halving
        flat = [q for g in groups for q, _ in g]
        mid = len(flat) // 2
        parts = [flat[:mid], flat[mid:]]
    for n, part_ids in enumerate(parts):
        res = build_pack(ctx, track, lo, hi, part_ids, letters[n])
        if res.tokens > limit:
            if len(part_ids) <= 1:
                raise PackTooLarge(f"single quest pack over limit: {part_ids}")
            raise PackTooLarge(
                f"{res.pack['id']} is ~{res.tokens} tokens after splitting; "
                "lower SPLIT_TARGET_FRACTION"
            )
        results.append(res)
    return results


def write_pack(out_dir: Path, result: PackResult) -> Path:
    pack = result.pack
    name = pack["id"].removeprefix(f"{pack['faction']}_")
    path = out_dir / f"{name}.json"
    path.write_text(result.text, encoding="utf-8", newline="\n")
    return path
