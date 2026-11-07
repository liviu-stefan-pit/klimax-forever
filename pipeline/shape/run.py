"""Orchestrates the shape step: filter, band packs, quest index, travel graph, report."""

from __future__ import annotations

import json
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from pipeline.shape.build_bands import (
    PACK_TOKEN_LIMIT,
    PackResult,
    all_bands,
    build_packs_for_track,
    estimate_tokens,
    plan_tracks,
    write_pack,
)
from pipeline.shape.context import FilterStats, ShapeContext
from pipeline.shape.data import DEFAULT_RAW, RawData, load_raw
from pipeline.shape.factions import FactionConfig, get_faction

DEFAULT_DATA = Path("data")
SOLO_EXCLUDED = ("elite", "group", "dungeon", "profession", "rep", "escort")


@dataclass
class ShapeResult:
    faction: str
    packs: list[PackResult] = field(default_factory=list)
    paths: list[Path] = field(default_factory=list)
    stats: FilterStats | None = None
    notes: dict[str, str] = field(default_factory=dict)
    unassigned: dict[str, dict[str, list[int]]] = field(default_factory=dict)
    travel_summary: dict[str, int] = field(default_factory=dict)


def _write_json(path: Path, value: Any) -> None:
    text = json.dumps(value, indent=1, sort_keys=True, ensure_ascii=False)
    path.write_text(text + "\n", encoding="utf-8", newline="\n")


def run_shape(
    faction: str,
    raw_dir: Path = DEFAULT_RAW,
    data_dir: Path = DEFAULT_DATA,
    progress: Callable[[str], None] | None = None,
    raw: RawData | None = None,
) -> ShapeResult:
    cfg = get_faction(faction)
    say = progress or (lambda _m: None)
    raw = raw or load_raw(raw_dir)
    ctx = ShapeContext(raw, cfg)
    ctx.build_quests()
    result = ShapeResult(faction=cfg.id, stats=ctx.stats)
    say(f"{ctx.stats.kept} of {ctx.stats.total} quests available to {cfg.id}")

    out = data_dir / cfg.id
    bands_dir = out / "bands"
    bands_dir.mkdir(parents=True, exist_ok=True)
    for stale in bands_dir.glob("*.json"):
        stale.unlink()

    index: dict[int, list[str]] = {}
    for lo, hi in all_bands(cfg):
        plan = plan_tracks(ctx, lo, hi)
        result.notes[f"{lo:02d}-{hi:02d}"] = plan.note
        if plan.orphans:
            by_zone: dict[str, list[int]] = {}
            for qid in plan.orphans:
                zone = ctx.quests[qid].zone
                name = ctx.zone_name(zone) if zone is not None else "(no zone)"
                by_zone.setdefault(name, []).append(qid)
            result.unassigned[f"{lo:02d}-{hi:02d}"] = {k: by_zone[k] for k in sorted(by_zone)}
        for track in sorted(plan.quests):
            qids = plan.quests[track]
            if not qids:
                continue
            for res in build_packs_for_track(ctx, track, lo, hi, qids):
                path = write_pack(bands_dir, res)
                result.packs.append(res)
                result.paths.append(path)
                for entry in res.pack["quests"]:
                    index.setdefault(entry["i"], []).append(res.pack["id"])
                say(f"{res.pack['id']}: {len(res.pack['quests'])} quests, ~{res.tokens} tokens")

    # Numeric id order, one quest per line; not key-sorted so "9" comes before "10".
    rows = [f'"{q}":{json.dumps(sorted(index[q]))}' for q in sorted(index)]
    body = "{\n" + ",\n".join(rows) + "\n}\n"
    (out / "quest_index.json").write_text(body, encoding="utf-8", newline="\n")
    _write_json(out / "unassigned.json", result.unassigned)

    from pipeline.shape.travel import build_travel

    travel = build_travel(ctx)
    transport_path = raw_dir / "game" / "transport.json"
    if transport_path.is_file():
        from pipeline.shape.game_merge import merge_game_transport

        transport = json.loads(transport_path.read_text(encoding="utf-8"))
        merge_game_transport(travel, transport, cfg.id)
        say(f"merged game transport data ({len(travel['transport']['links'])} links)")
    _write_json(out / "travel.json", travel)
    result.travel_summary = {
        "zones": len(travel["zones"]),
        "flightMasters": len(travel["flightMasters"]),
        "innkeepers": len(travel["innkeepers"]),
        "zeppelinPlatforms": len(travel["zeppelins"]["platforms"]),
        "vendors": len(travel["vendors"]),
        "classTrainers": sum(len(v) for v in travel["classTrainers"].values()),
    }
    return result


# ---- report -------------------------------------------------------------------------------


def pack_row(pack: dict[str, Any], tokens: int) -> dict[str, Any]:
    lo, hi = pack["band"]
    quests = pack["quests"]
    flag_counts: Counter[str] = Counter()
    for q in quests:
        for fl in q.get("fl", []):
            flag_counts["class" if fl.startswith("class:") else fl] += 1
    xp_all = sum(q.get("xp", 0) for q in quests)
    # "solo" pool: nothing elite/group/dungeon/profession/rep/escort and not class-gated.
    core = [
        q
        for q in quests
        if not any(f in SOLO_EXCLUDED or f.startswith("class:") for f in q.get("fl", []))
    ]
    xp_solo = sum(q.get("xp", 0) for q in core)
    return {
        "id": pack["id"],
        "quests": len(quests),
        "tokens": tokens,
        "xp_all": xp_all,
        "xp_solo": xp_solo,
        "budget": pack["xpBudget"],
        "flags": dict(sorted(flag_counts.items())),
        "zones": [z["n"] for z in pack["zones"][:4]],
        "n_zones": len(pack["zones"]),
        "hubs": [h["name"] for h in sorted(pack["hubs"], key=lambda h: -h["n"])[:4]],
        "n_hubs": len(pack["hubs"]),
    }


def format_report(result: ShapeResult, raw: RawData | None = None) -> str:
    rows = [pack_row(p.pack, p.tokens) for p in result.packs]
    lines: list[str] = []
    st = result.stats
    if st:
        lines += [
            f"Faction filter ({result.faction}): {st.total} quests in DB -> {st.kept} kept",
            f"  dropped: {st.wrong_faction} other faction, {st.placeholder} placeholder, "
            f"{st.hostile_starters} hostile starters, {st.no_starter} no starter "
            f"({st.no_starter_all_db} with no starter in the whole DB)",
            f"  class quests kept (tagged class:<TOKEN>): {st.class_quests}",
            f"  unexpected requiredRaces bits: {st.unusual_race_bits or 'none'}; "
            f"unknown class bits: {st.unknown_class_bits or 'none'}",
            "",
        ]
    head = (
        f"{'pack':<26}{'quests':>7}{'tokens':>8}{'xp(solo)':>10}{'xp(all)':>10}"
        f"{'budget':>9}{'solo/bud':>9}  flags / zones / hubs"
    )
    lines.append(head)
    lines.append("-" * len(head))
    for r in rows:
        flags = " ".join(f"{k}={v}" for k, v in r["flags"].items())
        ratio = f"{r['xp_solo'] / r['budget']:.1f}x" if r["budget"] else "-"
        lines.append(
            f"{r['id']:<26}{r['quests']:>7}{r['tokens']:>8}{r['xp_solo']:>10}{r['xp_all']:>10}"
            f"{r['budget']:>9}{ratio:>9}  {flags}"
        )
        zone_txt = ", ".join(r["zones"]) + (f" (+{r['n_zones'] - 4})" if r["n_zones"] > 4 else "")
        hub_txt = ", ".join(r["hubs"]) + (f" (+{r['n_hubs'] - 4})" if r["n_hubs"] > 4 else "")
        lines.append(f"{'':<26}  zones: {zone_txt}")
        lines.append(f"{'':<26}  hubs:  {hub_txt}")
    biggest = max((r["tokens"] for r in rows), default=0)
    lines += ["", f"largest pack: ~{biggest} tokens (limit {PACK_TOKEN_LIMIT})"]
    if result.notes:
        lines.append(
            "band notes: "
            + "; ".join(f"{k}: {v}" for k, v in sorted(result.notes.items()) if v != "shared")
        )
    if result.unassigned:
        lines.append("unassigned to any start branch (see data/<faction>/unassigned.json):")
        for band, zones in sorted(result.unassigned.items()):
            lines.append(f"  {band}: " + ", ".join(f"{z} {len(v)}" for z, v in zones.items()))
    if result.travel_summary:
        lines.append(
            "travel.json: " + ", ".join(f"{k}={v}" for k, v in result.travel_summary.items())
        )
    return "\n".join(lines)


def load_report_from_disk(faction: str, data_dir: Path = DEFAULT_DATA) -> ShapeResult:
    """Rebuild a ShapeResult from existing band files (for ``--report`` without a rebuild)."""
    result = ShapeResult(faction=faction)
    for path in sorted((data_dir / faction / "bands").glob("*.json")):
        text = path.read_text(encoding="utf-8")
        result.packs.append(PackResult(json.loads(text), text, estimate_tokens(text)))
    return result


def cfg_for(faction: str) -> FactionConfig:
    return get_faction(faction)
