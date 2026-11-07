"""Tests for the world compiler (phase 19): pure helpers, then end to end on data/raw."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from pipeline.world.config import WorldConfig
from pipeline.world.corrections import Corrections, CorrectionsError
from pipeline.world.hubs import HubMember, cluster_hubs
from pipeline.world.lua import lua_value, sync_toc
from pipeline.world.quests import xp_at_level
from pipeline.world.zones import level_range, weighted_percentile

RAW = Path("data/raw")
DATA = Path("data")
ADDON = Path("Klimax")

# ---- pure helpers -------------------------------------------------------------------------------


def test_xp_at_level_classic_falloff() -> None:
    assert xp_at_level(1000, 10, 10) == 1000
    assert xp_at_level(1000, 10, 15) == 1000
    assert xp_at_level(1000, 10, 16) == 800
    assert xp_at_level(1000, 10, 17) == 600
    assert xp_at_level(1000, 10, 19) == 200
    assert xp_at_level(1000, 10, 25) == 100
    # rounded down to a multiple of 5
    assert xp_at_level(333, 10, 16) == 265


def test_lua_value_sorts_keys_ints_first() -> None:
    text = lua_value({"b": 1, 2: "x", "a": [1, 2.5], 1: True})
    assert text == '{[1] = true, [2] = "x", a = {1, 2.5}, b = 1}'


def test_lua_value_quotes_reserved_and_odd_keys() -> None:
    assert lua_value({"end": 1, "a-b": 2}) == '{["a-b"] = 2, ["end"] = 1}'


def test_lua_value_is_independent_of_insertion_order() -> None:
    a = {"x": {"q": 1, "p": 2}, "y": [3, 4]}
    b = {"y": [3, 4], "x": {"p": 2, "q": 1}}
    assert lua_value(a) == lua_value(b)


def test_weighted_percentile_and_level_range() -> None:
    pairs = [(5, 10), (6, 10), (7, 10), (20, 1)]
    assert weighted_percentile(pairs, 0.5) == 6
    rng = level_range(pairs)
    assert rng is not None
    lo, mid, hi = rng
    assert lo <= mid <= hi
    assert hi < 20  # a single outlier quest does not stretch the range
    assert level_range([]) is None


def test_hubs_have_stable_anchor_ids_and_are_order_independent() -> None:
    def members() -> list[HubMember]:
        return [
            HubMember(("n", 10), 50.0, 50.0, {1, 2, 3}, {1}),
            HubMember(("n", 11), 51.0, 50.5, {4}, set()),
            HubMember(("o", 5), 80.0, 20.0, {9}, {9}),
        ]

    hubs = cluster_hubs(members(), 3.0, "durotar")
    again = cluster_hubs(list(reversed(members())), 3.0, "durotar")
    assert hubs == again
    ids = [h["id"] for h in hubs]
    assert ids == sorted(ids)
    assert "durotar:n10" in ids  # anchor: starts and ends the most quests
    assert "durotar:o5" in ids
    big = next(h for h in hubs if h["id"] == "durotar:n10")
    assert big["npcs"] == [10, 11]
    assert big["qs"] == [1, 2, 3, 4]


def test_corrections_reject_bad_input() -> None:
    with pytest.raises(CorrectionsError):
        Corrections.from_dict({"equivalents": [{"ids": [1]}]})


def test_sync_toc_inserts_world_block_once(tmp_path: Path) -> None:
    toc = tmp_path / "Klimax.toc"
    toc.write_text(
        "## Title: K\nCompat.lua\nRoutes\\Horde\\Index.lua\nCore.lua\n", encoding="utf-8"
    )

    class _Zone:
        def __init__(self, stem: str) -> None:
            self.file_stem = stem

    class _Model:
        zones = [_Zone("Durotar"), _Zone("Mulgore")]

    assert sync_toc(toc, _Model())  # type: ignore[arg-type]
    lines = toc.read_text(encoding="utf-8").splitlines()
    assert lines == [
        "## Title: K",
        "Compat.lua",
        "WorldDB.lua",
        "World\\Index.lua",
        "World\\Travel.lua",
        "World\\Durotar.lua",
        "World\\Mulgore.lua",
        "World\\Outside.lua",
        "Routes\\Horde\\Index.lua",
        "Core.lua",
    ]
    assert not sync_toc(toc, _Model())  # type: ignore[arg-type]


# ---- end to end (needs data/raw from `python -m pipeline extract`) ------------------------------

needs_raw = pytest.mark.skipif(not (RAW / "quests.json").exists(), reason="data/raw not extracted")


@pytest.fixture(scope="module")
def world():  # type: ignore[no-untyped-def]
    from pipeline.world.build import build_world, load_inputs

    raw, travel, corrections = load_inputs(RAW, DATA, "horde")
    return build_world(raw, travel, corrections, WorldConfig())


@pytest.fixture(scope="module")
def files(world):  # type: ignore[no-untyped-def]
    from pipeline.world.lua import world_files

    return world_files(world, ADDON / "World")


@needs_raw
def test_world_covers_the_start_zones(world) -> None:  # type: ignore[no-untyped-def]
    names = {z.enum for z in world.zones}
    assert {"DUROTAR", "MULGORE", "TIRISFAL_GLADES", "ZEPHRAS_ISLE"} <= names
    for zone in world.zones:
        assert world.tables[zone.ui_map]["quests"], zone.enum


@needs_raw
def test_known_quests_resolve(world) -> None:  # type: ignore[no-untyped-def]
    durotar = next(z for z in world.zones if z.enum == "DUROTAR")
    quests = world.tables[durotar.ui_map]["quests"]
    cutting = quests[788]
    assert cutting["n"] == "Cutting Teeth"
    assert cutting["sn"] == [3143] and cutting["en"] == [3143]
    assert 788 in quests[789]["po"]  # Sting of the Scorpid needs Cutting Teeth
    assert world.index["quests"][788] == durotar.ui_map


@needs_raw
def test_graph_validator_is_clean(world, files) -> None:  # type: ignore[no-untyped-def]
    from pipeline.world.validate import validate_world

    report = validate_world(world, files)
    assert report.ok, [i.as_dict() for i in report.errors]
    assert not report.warnings, [i.as_dict() for i in report.warnings]


@needs_raw
def test_compile_is_deterministic(files) -> None:  # type: ignore[no-untyped-def]
    from pipeline.world.build import build_world, load_inputs
    from pipeline.world.lua import world_files

    raw, travel, corrections = load_inputs(RAW, DATA, "horde")
    again = world_files(build_world(raw, travel, corrections, WorldConfig()), ADDON / "World")
    assert again == files


@needs_raw
def test_generated_files_are_up_to_date_and_in_budget(files) -> None:  # type: ignore[no-untyped-def]
    config = WorldConfig()
    for path, text in files.items():
        assert len(text.encode("utf-8")) <= config.size_budget, path
        if path.exists():
            assert path.read_text(encoding="utf-8") == text, f"{path} is stale: run compile-world"


@needs_raw
def test_generated_quest_keys_are_sorted(files) -> None:  # type: ignore[no-untyped-def]
    for path, text in files.items():
        ids = [int(m) for m in re.findall(r"^            \[(\d+)\] = ", text, re.M)]
        # every section lists integer keys ascending; a new section restarts the sequence
        runs: list[list[int]] = [[]]
        for a in ids:
            if runs[-1] and a < runs[-1][-1]:
                runs.append([])
            runs[-1].append(a)
        assert len(runs) <= 6, path  # quests, npcs, objects, items (+ index sections)


@needs_raw
def test_hub_ids_are_unique_and_prefixed(world) -> None:  # type: ignore[no-untyped-def]
    for zone in world.zones:
        hubs = world.tables[zone.ui_map].get("hubs", [])
        ids = [h["id"] for h in hubs]
        assert len(ids) == len(set(ids))
        assert all(i.startswith(zone.key + ":") for i in ids)


def test_corrections_file_is_valid_json_with_sorted_ids() -> None:
    path = DATA / "horde" / "world" / "corrections.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    Corrections.from_dict(data)
    for group in data.get("equivalents", []):
        assert group["ids"] == sorted(group["ids"])
