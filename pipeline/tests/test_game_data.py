"""Phase 03b: zone table, game transport merge, trainer spells, RXP id parser.

Synthetic tests run anywhere. Tests marked with ``needs_game`` / ``needs_questiedb`` skip when
the installed game or the vendored QuestieDB is absent.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pipeline.extract import game_travel, rxp_guides, trainer_spells
from pipeline.extract import support as support_mod
from pipeline.routes.ui_maps import (
    UI_MAPS_PATH,
    build_ui_map_table,
    load_ui_maps,
    ui_map_for,
)
from pipeline.shape.game_merge import merge_game_transport

REPO = Path(__file__).resolve().parents[2]
TRAVEL = REPO / "data" / "horde" / "travel.json"
QUESTIEDB = REPO / "QuestieDB"

needs_game = pytest.mark.skipif(
    not game_travel.DEFAULT_ADDONS.is_dir(), reason="World of Warcraft install not found"
)
needs_questiedb = pytest.mark.skipif(not QUESTIEDB.is_dir(), reason="QuestieDB not vendored")

# Real counts at the time of writing: 1,112 areaIdToUiMapId, 2,357 subZoneToParentZone,
# 97 uiMapIdToAreaId. The floors leave room for a QuestieDB refresh but catch a reader that
# silently drops the base tables (phase 01 bug: only the 47 override rows were read).
AREA_FLOOR, SUBZONE_FLOOR, UIMAP_FLOOR = 1000, 2000, 90


@needs_questiedb
def test_zone_extractor_reads_base_and_override_tables() -> None:
    report = support_mod.SupportReport()
    zones = support_mod.load_zone_maps(QUESTIEDB, report)
    assert len(zones["areaIdToUiMapId"]) >= AREA_FLOOR
    assert len(zones["subZoneToParentZone"]) >= SUBZONE_FLOOR
    assert len(zones["uiMapIdToAreaId"]) >= UIMAP_FLOOR
    # Durotar is only in the base table; Zephra's Isle and Riverglades are Forever-only.
    assert zones["areaIdToUiMapId"][14] == 1411
    assert zones["areaIdToUiMapId"][16593] == 2521
    assert zones["areaIdToUiMapId"][16591] == 2548
    # An override wins over the base table (synthetic area 10073 is the Kalimdor map).
    assert zones["areaIdToUiMapId"][10073] == 1414
    assert not [s for s in report.skipped if "areaIdToUiMapId" in s["file"]]


def test_committed_ui_map_table_has_a_sane_size() -> None:
    table = load_ui_maps()
    assert len(table) >= AREA_FLOOR
    assert table[16593] == 2521 and table[16591] == 2548


def test_every_travel_zone_resolves_to_a_ui_map() -> None:
    travel = json.loads(TRAVEL.read_text(encoding="utf-8"))
    missing = [z["name"] for z in travel["zones"] if not ui_map_for(z["id"])]
    assert not missing


def test_ui_map_for_zero_means_no_map_and_overrides_win(monkeypatch: pytest.MonkeyPatch) -> None:
    assert ui_map_for(2257) is None  # Deeprun Tram: display suppressed (0), not a real map
    assert ui_map_for(14, {14: 9999}) == 9999
    assert ui_map_for(14, {14: 0}) == 1411
    monkeypatch.setattr("pipeline.routes.ui_maps.OVERRIDES", {14: 1})
    assert ui_map_for(14, {14: 9999}) == 1


def test_build_ui_map_table_drops_suppressed_rows() -> None:
    table = build_ui_map_table({"areaIdToUiMapId": {14: 1411, 0: 0, 2257: 0}}, {"x": "y"})
    assert table["areaIdToUiMapId"] == {"14": 1411}
    assert UI_MAPS_PATH.name == "ui_maps.json"


def test_split_travel_label() -> None:
    assert game_travel.split_travel_label("Boat to Booty Bay, Stranglethorn") == {
        "mode": "boat", "place": "Booty Bay", "region": "Stranglethorn",
    }
    assert game_travel.split_travel_label("Zeppelin to Zephras Isle")["place"] == "Zephras Isle"
    assert game_travel.split_travel_label("Arrow")["mode"] is None


def test_parse_guide_text_keeps_ids_and_steps_only() -> None:
    text = "\n".join(
        [
            "RXPGuides.RegisterGuide([[",
            "step",
            "    .accept 100 >>Accept Something",
            "--    .accept 999 >>commented out",
            "step << Mage",
            "    .complete 100,1 << Mage",
            "    .turnin 100",
            "]])",
            "RXPGuides.RegisterGuide([[",
            "step",
            "    .accept 200",
        ]
    )
    guides = rxp_guides.parse_guide_text(text)
    assert [g["index"] for g in guides] == [1, 2]
    assert guides[0]["steps"] == [
        [1, "accept", 100, False],
        [2, "complete", 100, True],
        [2, "turnin", 100, False],
    ]
    assert guides[1]["steps"] == [[1, "accept", 200, False]]


def _travel() -> dict:
    return {
        "zones": [
            {"id": 14, "enum": "DUROTAR", "name": "Durotar"},
            {"id": 215, "enum": "MULGORE", "name": "Mulgore"},
            {"id": 16593, "enum": "ZEPHRAS_ISLE", "name": "Zephra's Isle"},
        ],
        "flightMasters": [
            {"id": 1, "zone": 14, "x": 52.0, "y": 41.0, "nodeName": "Razor Hill, Durotar"},
            {"id": 2, "zone": 215, "x": 10.0, "y": 10.0, "nodeName": "Far, Mulgore"},
        ],
        "manual": {
            "adjacency": [
                {"a": "DUROTAR", "b": "MULGORE", "via": "hand-typed"},
            ],
            "zeppelinRoutes": [],
            "boatRoutes": [],
        },
    }


def _transport() -> dict:
    return {
        "sources": [{"file": "a"}, {"file": "b"}, {"file": "c"}],
        "flightPoints": [
            {"faction": "Horde", "uiMapId": 1411, "x": 52.3, "y": 41.2, "label": "Razor Hill"},
            {"faction": "Alliance", "uiMapId": 1412, "x": 10.0, "y": 10.0, "label": "Nope"},
        ],
        "links": [
            {
                "faction": "Horde", "mode": "zeppelin", "place": "Zephras Isle",
                "uiMapId": 1412, "x": 34.3, "y": 26.1, "destUiMapId": 2521,
                "label": "Zeppelin to Zephras Isle",
            },
            {
                "faction": "Alliance", "mode": "boat", "place": "Zephras Isle",
                "uiMapId": 1416, "x": 12.8, "y": 51.2, "destUiMapId": 2521, "label": "x",
            },
        ],
        "zoneTree": {"1411": {"neighbors": [1413]}},
    }


def test_merge_game_transport_marks_verified_and_lists_contradictions() -> None:
    travel = merge_game_transport(_travel(), _transport())
    first, second = travel["flightMasters"]
    assert first["nodeName"] == "Razor Hill" and first["verified"] is True
    assert second["nodeName"] == "Far, Mulgore" and second["verified"] is False
    links = travel["transport"]["links"]
    assert [(lk["kind"], lk["from"]["zone"], lk["to"]["zone"]) for lk in links] == [
        ("zeppelin", "MULGORE", "ZEPHRAS_ISLE")
    ]  # the Alliance boat is not a Horde link
    assert links[0]["verified"] is True and links[0]["source"].startswith("Leatrix_Maps")
    assert travel["manual"]["adjacency"][0]["gameNeighbor"] is False
    assert [c["what"] for c in travel["gameCheck"]["contradictions"]] == [
        "adjacency: DUROTAR - MULGORE"
    ]


@needs_game
def test_real_leatrix_data_settles_the_zephras_isle_hand_off() -> None:
    icons = game_travel.read_leatrix(game_travel.DEFAULT_ADDONS / game_travel.LEATRIX)
    zeppelins = [
        row for row in icons
        if row["group"] == "travel" and row["faction"] == "Horde" and row["destUiMapId"] == 2521
    ]
    assert [(r["uiMapId"], r["x"], r["y"]) for r in zeppelins] == [(1412, 34.3, 26.1)]


@needs_game
def test_real_trainer_spells_cover_nine_classes() -> None:
    data = trainer_spells.build_trainer_spells()
    assert sorted(data["classes"]) == sorted(trainer_spells.CLASS_FILES)
    for rows in data["classes"].values():
        assert rows and rows[0]["level"] == 1 and rows[-1]["level"] == 60


def test_raid_ids_come_from_raid_names_only() -> None:
    from pipeline.shape.data import RAID_NAMES, RawData

    raw = RawData({}, {}, {}, {}, {}, {}, {}, {})
    raw.dungeon_names = {1: "Molten Core", 2: "Blackrock Depths", 3: "Zul'Gurub"}
    assert raw.raid_ids == {1, 3}
    assert "Blackrock Spire" not in RAID_NAMES and "Stratholme" not in RAID_NAMES
