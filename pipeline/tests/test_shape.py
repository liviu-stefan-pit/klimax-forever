"""Tests for the shape step: filters, band membership, clustering, size guard, determinism."""

from __future__ import annotations

import random
from pathlib import Path
from typing import Any

import pytest

from pipeline.extract.normalize import normalize_objectives
from pipeline.shape import flags as flagmod
from pipeline.shape.build_bands import (
    CHARS_PER_TOKEN,
    PACK_TOKEN_LIMIT,
    PackTooLarge,
    all_bands,
    check_pack_size,
    dump_pack,
    plan_tracks,
    split_ids,
)
from pipeline.shape.context import (
    ShapeContext,
    effective_level,
    in_band,
    race_available,
    race_restriction,
)
from pipeline.shape.coords import cluster_spawns, dbscan, find_hubs, pick_spawn, valid_spawns
from pipeline.shape.data import RawData
from pipeline.shape.factions import HORDE
from pipeline.shape.run import run_shape
from pipeline.shape.xp_table import XP_TO_NEXT, xp_for_levels

HORDE_FLAG = 1 << 33
ALLIANCE_FLAG = 1 << 32
ALLIANCE_RACES = 1 | 4 | 8 | 64  # Human, Dwarf, Night Elf, Gnome


# ---- race / faction filter ----------------------------------------------------------------


def test_horde_race_mask_is_178() -> None:
    assert HORDE.race_mask == 178 == 2 | 16 | 32 | 128


@pytest.mark.parametrize(
    ("mask", "expected"),
    [
        (0, True),  # open to everyone
        (HORDE_FLAG | 178, True),  # Forever's "all Horde" form
        (HORDE_FLAG | 32, True),  # Tauren with the Horde flag
        (ALLIANCE_FLAG | ALLIANCE_RACES, False),  # "all Alliance" form
        (ALLIANCE_FLAG, False),  # Alliance flag alone
        (ALLIANCE_FLAG | 8, False),
        (HORDE_FLAG | ALLIANCE_FLAG, True),  # both flags: neutral
        (5, False),  # Human + Dwarf
        (16, True),  # Undead only
        (2 | 128, True),
    ],
)
def test_race_available(mask: int, expected: bool) -> None:
    assert race_available(mask, HORDE) is expected


def test_race_restriction() -> None:
    assert race_restriction(0, HORDE) is None
    assert race_restriction(HORDE_FLAG | 178, HORDE) is None  # every Horde race: not restricted
    assert race_restriction(HORDE_FLAG, HORDE) is None
    assert race_restriction(2 | 128, HORDE) == ("Orc", "Troll")
    assert race_restriction(HORDE_FLAG | 32, HORDE) == ("Tauren",)


# ---- band membership ----------------------------------------------------------------------


def test_bands_are_twelve_and_start_at_one() -> None:
    bands = all_bands(HORDE)
    assert len(bands) == 12
    assert bands[0] == (1, 5)
    assert bands[1] == (5, 10)
    assert bands[-1] == (55, 60)


@pytest.mark.parametrize(
    ("level", "lo", "hi", "expected"),
    [(3, 5, 10, True), (2, 5, 10, False), (12, 5, 10, True), (13, 5, 10, False), (-1, 1, 5, True)],
)
def test_in_band_overlap(level: int, lo: int, hi: int, expected: bool) -> None:
    assert in_band(level, lo, hi) is expected


def test_effective_level_handles_scaling_quests() -> None:
    assert effective_level({"questLevel": 12, "requiredLevel": 10}) == 12
    assert effective_level({"questLevel": -1, "requiredLevel": 40}) == 40
    assert effective_level({"questLevel": 0, "requiredLevel": 0}) == 1


# ---- clustering ---------------------------------------------------------------------------


def _points() -> list[tuple[int, float, float]]:
    camp_a = [(14, 40.0 + dx, 60.0 + dy) for dx in (0, 1, 2) for dy in (0, 1)]
    camp_b = [(14, 70.0 + dx, 20.0 + dy) for dx in (0, 1) for dy in (0, 1, 2)]
    lone = [(14, 10.0, 10.0), (17, 50.0, 50.0)]
    return camp_a + camp_b + lone


def test_cluster_spawns_finds_two_camps_and_is_order_independent() -> None:
    pts = _points()
    base, total = cluster_spawns(pts)
    assert total == len(pts)
    assert [c.count for c in base] == [6, 6]
    assert {round(c.x) for c in base} == {41, 70}
    for seed in range(5):
        shuffled = pts[:]
        random.Random(seed).shuffle(shuffled)
        assert cluster_spawns(shuffled) == (base, total)


def test_noise_points_become_singleton_clusters() -> None:
    clusters, total = cluster_spawns([(14, 10.0, 10.0)], max_clusters=5)
    assert total == 1
    assert clusters[0].count == 1
    assert clusters[0].radius == 0


def test_dbscan_labels_are_deterministic() -> None:
    pts = [(x, y) for x, y, _ in [(1, 1, 0), (2, 1, 0), (1, 2, 0), (50, 50, 0)]]
    assert dbscan(pts, 4.0, 2) == dbscan(list(pts), 4.0, 2) == [0, 0, 0, -1]


def test_sentinel_spawns_are_skipped() -> None:
    assert valid_spawns({"14": [[-1, -1], [10.5, 20.5]], "x": [[1, 1]]}) == [(14, 10.5, 20.5)]


def test_pick_spawn_prefers_hub_and_is_deterministic() -> None:
    hub_points = [(14, 50.0, 40.0), (14, 51.0, 41.0), (14, 52.0, 40.0)]
    hubs = find_hubs(hub_points)
    assert len(hubs) == 1
    far, near = (14, 10.0, 10.0), (14, 51.5, 40.5)
    assert pick_spawn([far, near], hubs) == near
    assert pick_spawn([near, far], hubs) == near
    assert pick_spawn([far, (14, 20.0, 20.0)], []) == (14, 10.0, 10.0)  # no hubs: sorted first


# ---- filters on a synthetic database ------------------------------------------------------


def _raw(quests: dict[int, dict[str, Any]], npcs: dict[int, dict[str, Any]]) -> RawData:
    zone_by_name = {
        "DUROTAR": 14,
        "ORGRIMMAR": 1637,
        "MULGORE": 215,
        "THUNDER_BLUFF": 1638,
        "TIRISFAL_GLADES": 85,
        "UNDERCITY": 1497,
        "THE_BARRENS": 17,
        "SILVERPINE_FOREST": 130,
        "ZEPHRAS_ISLE": 9000,
    }
    return RawData(
        quests=quests,
        npcs=npcs,
        objects={},
        items={},
        xp={},
        zones={},
        manifest={},
        objective_hints={},
        zone_by_name=zone_by_name,
        zone_by_id={v: k for k, v in zone_by_name.items()},
    )


def _quest(
    starter_npc: int | None, mask: int = 0, level: int = 3, classes: int = 0, **extra: Any
) -> dict[str, Any]:
    giver = {"npcs": [starter_npc] if starter_npc else [], "objects": [], "items": []}
    quest = {
        "name": "Q",
        "startedBy": giver,
        "finishedBy": {"npcs": [], "objects": [], "items": []},
        "questLevel": level,
        "requiredLevel": 1,
        "requiredRaces": mask,
        "requiredClasses": classes,
        "objectives": {},
    }
    quest.update(extra)
    return quest


def _npc(friendly: str | None, zone: int = 14, x: float = 50.0) -> dict[str, Any]:
    npc: dict[str, Any] = {"name": "N", "spawns": {str(zone): [[x, 40.0]]}}
    if friendly:
        npc["friendlyToFaction"] = friendly
    return npc


def test_faction_filter_drops_hostile_placeholder_nostarter_and_other_faction() -> None:
    raw = _raw(
        {
            1: _quest(10),  # kept
            2: _quest(11),  # starter friendly only to the Alliance: hostile
            3: _quest(None),  # no starter at all
            4: _quest(10, mask=ALLIANCE_FLAG | ALLIANCE_RACES),  # Alliance quest
            5: _quest(10, placeholder=True),
            6: _quest(10, classes=4),  # class quest: kept and tagged
            7: _quest(12),  # starter with unknown faction: kept
        },
        {10: _npc("H"), 11: _npc("A"), 12: _npc(None)},
    )
    ctx = ShapeContext(raw, HORDE)
    ctx.build_quests()
    assert sorted(ctx.quests) == [1, 6, 7]
    assert ctx.quests[6].classes == ["HUNTER"]
    st = ctx.stats
    assert (st.hostile_starters, st.no_starter, st.wrong_faction, st.placeholder) == (1, 1, 1, 1)
    assert st.kept == 3


def test_split_bands_assign_branches_by_zone_and_race() -> None:
    raw = _raw(
        {
            1: _quest(10, mask=HORDE_FLAG | 178),  # Durotar, open to all
            2: _quest(20, mask=HORDE_FLAG | 32),  # Mulgore, Tauren
            3: _quest(30, mask=16),  # Tirisfal, Undead
            4: _quest(10, mask=16),  # Durotar but Undead only: nobody's branch
            5: _quest(40),  # Barrens, level 3: outside the reach window for band 1-5
        },
        {
            10: _npc("H", zone=14),
            20: _npc("H", zone=215),
            30: _npc("H", zone=85),
            40: _npc("H", zone=17),
        },
    )
    ctx = ShapeContext(raw, HORDE)
    ctx.build_quests()
    plan = plan_tracks(ctx, 1, 5)
    assert {k: v for k, v in plan.quests.items() if v} == {
        "durotar": [1],
        "mulgore": [2],
        "tirisfal": [3],
    }
    # 4: Undead-only quest in Durotar; 5: Barrens is only in reach from level 5.
    assert plan.orphans == [4, 5]
    assert plan_tracks(ctx, 5, 10).quests["durotar"] == [1, 5]


# ---- flags --------------------------------------------------------------------------------


def test_class_tokens() -> None:
    assert flagmod.class_tokens(4) == ["HUNTER"]
    assert flagmod.class_tokens(1024 | 128) == ["DRUID", "MAGE"]
    assert flagmod.class_tokens(2048) == ["BIT11"]


def test_escort_heuristic() -> None:
    plain = {"name": "Escort the Peasant", "objectivesText": ["x"]}
    event_only = {
        "name": "Dance",
        "objectivesText": ["Watch the dance."],
        "questFlags": 2,
        "specialFlags": 2,
    }
    event_escort = {
        "name": "Rescue Him",
        "objectivesText": ["Protect him."],
        "questFlags": 2,
        "specialFlags": 2,
    }
    assert flagmod.is_escort(plain)
    assert not flagmod.is_escort(event_only)
    assert flagmod.is_escort(event_escort)


def test_group_heuristic() -> None:
    assert flagmod.is_group({"questFlags": 64}, [])
    assert flagmod.is_group({"objectivesText": ["Bring a group of 5 players"]}, [])
    assert flagmod.is_group({}, [3])
    assert not flagmod.is_group({"objectivesText": ["Kill 10 boars"]}, [1, 0])


# ---- size guard ---------------------------------------------------------------------------


def test_check_pack_size_raises_over_limit() -> None:
    ok = "x" * (PACK_TOKEN_LIMIT * CHARS_PER_TOKEN)
    assert check_pack_size(ok) == PACK_TOKEN_LIMIT
    with pytest.raises(PackTooLarge):
        check_pack_size(ok + "xxxxx")


def test_split_ids_never_drops_and_respects_budget() -> None:
    groups = [
        [(qid, 100) for qid in range(start, start + n)]
        for start, n in ((0, 30), (100, 50), (200, 10), (300, 90))
    ]
    all_ids = sorted(q for g in groups for q, _ in g)
    parts = split_ids(groups, limit_chars=6_000, overhead=1_000)
    assert sorted(q for p in parts for q in p) == all_ids  # nothing dropped, nothing doubled
    sizes = [len(p) * 100 for p in parts]
    assert all(s <= 5_000 for s in sizes)
    assert len(parts) >= 3


def test_split_ids_single_part_when_it_fits() -> None:
    parts = split_ids([[(1, 10), (2, 10)], [(3, 10)]], limit_chars=10_000, overhead=100)
    assert parts == [[1, 2, 3]]


def test_dump_pack_is_independent_of_key_order() -> None:
    a = {"quests": [{"b": 1, "a": 2}], "id": "x", "band": [1, 5], "hubs": []}
    b = {"hubs": [], "band": [1, 5], "id": "x", "quests": [{"a": 2, "b": 1}]}
    assert dump_pack(a) == dump_pack(b)


# ---- misc ---------------------------------------------------------------------------------


def test_xp_table_is_complete_and_budgets_add_up() -> None:
    assert sorted(XP_TO_NEXT) == list(range(1, 60))
    assert xp_for_levels(1, 5) == 400 + 900 + 1400 + 2100
    assert xp_for_levels(55, 60) == 180800 + 187900 + 195000 + 202300 + 209800


def test_extractor_reads_sparse_objective_maps() -> None:
    """Regression: a Lua table with holes is stored as a CBOR map, ``{3: [...]}``."""
    assert normalize_objectives({3: [[5087, None]]}) == {"item": [[5087, None, 0]]}
    assert normalize_objectives([[[6, None]], None, None]) == {"creature": [[6, None, 0]]}


# ---- end to end (needs data/raw from `python -m pipeline extract`) -------------------------

RAW = Path("data/raw")


@pytest.mark.skipif(not (RAW / "quests.json").exists(), reason="data/raw not extracted")
def test_horde_shape_is_deterministic_and_packs_fit(tmp_path: Path) -> None:
    first = run_shape("horde", RAW, tmp_path / "a")
    second = run_shape("horde", RAW, tmp_path / "b")
    assert [p.pack["id"] for p in first.packs] == [p.pack["id"] for p in second.packs]
    for pa, pb in zip(first.paths, second.paths, strict=True):
        assert pa.read_bytes() == pb.read_bytes()
    for name in ("quest_index.json", "travel.json", "unassigned.json"):
        assert (tmp_path / "a/horde" / name).read_bytes() == (
            tmp_path / "b/horde" / name
        ).read_bytes()
    assert all(p.tokens <= PACK_TOKEN_LIMIT for p in first.packs)
    ids = {p.pack["id"] for p in first.packs}
    assert {"horde_durotar_01-05", "horde_mulgore_01-05", "horde_tirisfal_01-05"} <= ids
    assert len(first.packs) >= 12


def test_zephras_home_quests_get_their_own_10_15_pack() -> None:
    raw = _raw(
        {1: _quest(10, level=12), 2: _quest(50, level=12), 3: _quest(60, level=12)},
        {10: _npc("H", zone=9000), 50: _npc("H", zone=17), 60: _npc("H", zone=85)},
    )
    ctx = ShapeContext(raw, HORDE)
    ctx.build_quests()
    plan = plan_tracks(ctx, 10, 15)
    assert plan.quests["zephras"] == [1]
    assert 1 not in plan.quests.get("horde", [])
