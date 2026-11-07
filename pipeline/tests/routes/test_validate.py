"""Validator tests: one fixture per error rule, a few warning fixtures, stitching, stats."""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from pipeline.routes.validate_route import ERROR, WARNING, validate_curated, validate_route
from pipeline.tests.routes.helpers import (
    FIXTURES,
    build_world,
    codes,
    load,
    validate_fixture,
    with_pack_elite,
)

# fixture -> (error code, 1-based step or None for route level)
ERROR_CASES = [
    ("err_unknown_quest", "E_UNKNOWN_QUEST", 2),
    ("err_wrong_faction", "E_FACTION_QUEST", 2),
    ("err_turnin_before_accept", "E_TURNIN_BEFORE_ACCEPT", 4),
    ("err_complete_without_accept", "E_COMPLETE_BEFORE_ACCEPT", 4),
    ("err_missing_prerequisite", "E_PREREQ", 1),
    ("err_exclusive_pair", "E_EXCLUSIVE", 10),
    ("err_coordinates_off", "E_COORDS", 1),
    ("err_wrong_zone", "E_WRONG_ZONE", 2),
    ("err_min_level_too_low", "E_MIN_LEVEL", 10),
    ("err_unaccounted_quest", "E_UNACCOUNTED", None),
    ("err_class_quest_without_filter", "E_CLASS_QUEST", 2),
    ("err_unknown_zone", "E_UNKNOWN_ZONE", 1),
    ("err_duplicate_accept", "E_DUPLICATE", 3),
    ("err_dropped_and_used", "E_DROPPED_AND_USED", None),
    ("err_schema", "E_SCHEMA", 1),
]

WARNING_CASES = [
    ("warn_backtracking", "W_BACKTRACK"),
    ("warn_trainer_gap", "W_TRAINER_GAP"),
    ("warn_xp_range", "W_XP_RANGE"),
    ("warn_mob_level", "W_MOB_LEVEL"),
    ("warn_flight_master_missed", "W_FP_MISSED"),
    ("warn_excursion", "W_EXCURSION"),
    ("warn_open_quest", "W_OPEN_QUEST"),
]


def test_valid_tiny_route_is_clean() -> None:
    report = validate_fixture("valid_tiny")
    assert report.issues == []
    assert report.ok
    assert report.stats["steps"] == 9
    assert report.stats["byType"]["TRAINER"] == 2
    assert report.stats["quests"] == {"main": 3, "optional": 0, "optional-elite": 0}
    assert report.stats["dropped"] == 1
    assert 1.0 <= report.stats["xp"]["ratio"] <= 1.4


@pytest.mark.parametrize(("name", "code", "step"), ERROR_CASES)
def test_error_fixture(name: str, code: str, step: int | None) -> None:
    report = validate_fixture(name)
    assert not report.ok
    match = [i for i in report.issues if i.code == code and i.severity == ERROR]
    assert match, f"{name}: expected {code}, got {codes(report)}"
    assert any(i.step == step for i in match), f"{name}: {code} at {[i.step for i in match]}"


def test_elite_quest_cannot_be_dropped() -> None:
    world = with_pack_elite(build_world(), 4)  # valid_tiny drops quest 4
    report = validate_fixture("valid_tiny", world=world)
    assert "E_ELITE_DROPPED" in codes(report, ERROR)


@pytest.mark.parametrize(("name", "code"), WARNING_CASES)
def test_warning_fixture(name: str, code: str) -> None:
    report = validate_fixture(name)
    assert report.ok, f"{name} should have no errors, got {codes(report, ERROR)}"
    assert code in codes(report, WARNING)


def test_error_messages_say_how_to_fix() -> None:
    report = validate_fixture("err_coordinates_off")
    message = next(i.message for i in report.issues if i.code == "E_COORDS")
    assert "x=43.29" in message and "y=68.53" in message  # tells the fixer the right position
    report = validate_fixture("err_missing_prerequisite")
    message = next(i.message for i in report.issues if i.code == "E_PREREQ")
    assert "First Steps" in message and "dropped[]" in message


def test_issue_labels_use_step_type_and_quest() -> None:
    report = validate_fixture("err_unknown_quest")
    issue = next(i for i in report.issues if i.code == "E_UNKNOWN_QUEST")
    assert issue.step == 2 and issue.step_label == "ACCEPT 99999"


def test_coordinate_tolerance_boundary() -> None:
    route = load("valid_tiny")
    route["steps"][0].update(x=43.3 + 2.9, y=68.5)  # inside 3.0
    assert "E_COORDS" not in codes(validate_route(route, build_world()))
    route["steps"][0].update(x=43.3 + 3.2, y=68.5)  # outside
    assert "E_COORDS" in codes(validate_route(route, build_world()))


def test_minlevel_equal_to_required_level_is_fine() -> None:
    route = load("err_min_level_too_low")
    route["steps"][9]["minLevel"] = 10
    assert "E_MIN_LEVEL" not in codes(validate_route(route, build_world()))


def test_review_note_marks_a_warning_reviewed() -> None:
    route = load("warn_trainer_gap")
    route["_review"] = "Trainer is in the next band by design."
    report = validate_route(route, build_world())
    gap = next(i for i in report.issues if i.code == "W_TRAINER_GAP")
    assert gap.reviewed == "Trainer is in the next band by design."


# ---- stitching ---------------------------------------------------------------------------


def test_entry_must_match_previous_exit() -> None:
    report = validate_fixture("err_stitch_entry_mismatch", others=["stitch_prev"])
    issue = next(i for i in report.issues if i.code == "E_ENTRY_MISMATCH")
    assert "zone" in issue.message and "level" in issue.message and "hub" in issue.message


def test_matching_entry_passes() -> None:
    report = validate_fixture("stitch_next_ok", others=["stitch_prev"])
    assert "E_ENTRY_MISMATCH" not in codes(report)
    assert report.ok


def test_entry_level_may_differ_by_one() -> None:
    route = load("stitch_next_ok")
    route["entry"]["level"] = 6
    prev = load("stitch_prev")
    report = validate_route(route, build_world(), {prev["id"]: prev})
    assert "E_ENTRY_MISMATCH" not in codes(report)
    route["entry"]["level"] = 7
    report = validate_route(route, build_world(), {prev["id"]: prev})
    assert "E_ENTRY_MISMATCH" in codes(report)


def test_stitched_mode_reports_a_missing_next_route() -> None:
    report = validate_fixture("stitch_prev", stitched=True)
    assert "E_STITCH_NEXT_MISSING" in codes(report, ERROR)
    # without --stitched the same thing is only a warning
    assert validate_fixture("stitch_prev").ok


def test_stitched_band_gap_and_branch_are_errors() -> None:
    prev = load("stitch_prev")
    nxt = load("stitch_next_ok")
    nxt["band"] = [7, 12]
    nxt["id"] = "horde_durotar_07-12"
    prev["next"] = nxt["id"]
    report = validate_route(prev, build_world(), {nxt["id"]: nxt}, stitched=True)
    assert "E_STITCH_BAND_GAP" in codes(report, ERROR)
    nxt = load("stitch_next_ok")
    nxt["branch"] = "mulgore"
    nxt["id"] = "horde_mulgore_05-10"
    prev["next"] = nxt["id"]
    report = validate_route(prev, build_world(), {nxt["id"]: nxt}, stitched=True)
    assert "E_STITCH_BRANCH" in codes(report, ERROR)


def test_orphan_band_is_reported_when_stitched() -> None:
    route = load("stitch_next_ok")
    assert "W_NO_PREDECESSOR" in codes(validate_route(route, build_world()), WARNING)
    assert "E_STITCH_ORPHAN" in codes(validate_route(route, build_world(), stitched=True), ERROR)


def test_prerequisite_met_in_previous_band_counts() -> None:
    prev = load("stitch_prev")
    nxt = load("stitch_next_ok")
    # quest 4 needs quest 2, which stitch_prev turned in
    nxt["steps"] = [
        {"type": "ACCEPT", "quest": 4, "tag": "optional", "zone": "Durotar", "x": 42.1, "y": 68.3}
    ]
    report = validate_route(nxt, build_world(), {prev["id"]: prev})
    assert "E_PREREQ" not in codes(report)
    # ... but quest 4 excludes quest 3, which the previous band accepted
    exclusive = [i for i in report.issues if i.code == "E_EXCLUSIVE"]
    assert exclusive and "earlier band" in exclusive[0].message


def test_prerequisite_missing_from_previous_band_is_an_error() -> None:
    prev = load("stitch_prev")
    prev["steps"] = [s for s in prev["steps"] if s.get("quest") not in (2, 3)]  # never does 2
    prev["dropped"] += [
        {"quest": 2, "reason": "skipped for this test"},
        {"quest": 3, "reason": "skipped for this test"},
    ]
    nxt = load("stitch_next_ok")
    nxt["steps"] = [
        {"type": "ACCEPT", "quest": 4, "tag": "optional", "zone": "Durotar", "x": 42.1, "y": 68.3}
    ]
    report = validate_route(nxt, build_world(), {prev["id"]: prev})
    assert "E_PREREQ" in codes(report, ERROR)


# ---- misc rules --------------------------------------------------------------------------


def test_sample_route_downgrades_unaccounted_quests() -> None:
    route = load("err_unaccounted_quest")
    route["sample"] = True
    report = validate_route(route, build_world())
    assert report.ok
    assert "W_UNACCOUNTED" in codes(report, WARNING)


def test_wrong_db_stamp_is_a_warning() -> None:
    route = load("valid_tiny")
    route["db"]["buildCommit"] = "deadbeef"
    report = validate_route(route, build_world())
    assert report.ok and "W_DB_STAMP" in codes(report, WARNING)


def test_id_must_match_branch_and_band() -> None:
    route = load("valid_tiny")
    route["id"] = "horde_durotar_05-10"
    assert "E_ID" in codes(validate_route(route, build_world()), ERROR)


def test_race_restricted_quest_needs_races_filter() -> None:
    world = build_world()
    world.quests[2]["requiredRaces"] = world.faction.race_bits["Troll"]
    route = load("valid_tiny")
    report = validate_route(route, world)
    assert "E_RACE_QUEST" in codes(report, ERROR)
    for index in (3, 4, 5):
        route["steps"][index]["races"] = ["Troll"]
    assert "E_RACE_QUEST" not in codes(validate_route(route, world))


def test_class_filter_satisfies_class_quest() -> None:
    route = load("err_class_quest_without_filter")
    route["steps"][1]["classes"] = ["WARRIOR"]
    assert "E_CLASS_QUEST" not in codes(validate_route(route, build_world()))
    route["steps"][1]["classes"] = ["MAGE"]
    assert "E_CLASS_QUEST" in codes(validate_route(route, build_world()))


def test_unknown_npc_is_an_error() -> None:
    route = load("valid_tiny")
    route["steps"][2]["npc"] = 424242
    assert "E_UNKNOWN_NPC" in codes(validate_route(route, build_world()), ERROR)


def test_validator_does_not_mutate_the_route() -> None:
    route = load("warn_backtracking")
    before = copy.deepcopy(route)
    validate_route(route, build_world())
    assert route == before


def test_every_fixture_is_exercised() -> None:
    used = {n for n, *_ in ERROR_CASES} | {n for n, _ in WARNING_CASES}
    used |= {"valid_tiny", "stitch_prev", "stitch_next_ok", "err_stitch_entry_mismatch"}
    on_disk = {p.name[: -len(".route.json")] for p in Path(FIXTURES).glob("*.route.json")}
    assert on_disk == used


# ---- curation files ----------------------------------------------------------------------


def test_curated_schema_and_pack_coverage() -> None:
    good = {
        "schemaVersion": 1,
        "id": "horde_durotar_01-05",
        "decisions": [
            {"quest": 1, "decision": "main", "reason": "start of the chain"},
            {"quest": 2, "decision": "main", "reason": "chain"},
            {"quest": 3, "decision": "optional", "reason": "reward"},
            {"quest": 4, "decision": "drop", "reason": "exclusive with 3"},
        ],
    }
    assert validate_curated(good, build_world()) == []
    bad = json.loads(json.dumps(good))
    bad["decisions"][0]["decision"] = "maybe"
    assert validate_curated(bad)[0].code == "E_SCHEMA"
    short = json.loads(json.dumps(good))
    short["decisions"].pop()
    assert "E_UNACCOUNTED" in [i.code for i in validate_curated(short, build_world())]
    assert "E_ELITE_DROPPED" in [
        i.code for i in validate_curated(good, with_pack_elite(build_world(), 4))
    ]
    revisit = json.loads(json.dumps(good))
    revisit["decisions"][1]["revisitAt"] = 8  # only valid on optional-elite
    assert validate_curated(revisit)[0].code == "E_SCHEMA"


def test_self_and_exclusive_prerequisites_are_ignored() -> None:
    """QuestieDB lists race variants (1516, 1519) as their own 'any one of' prerequisites."""
    world = build_world()
    quest = world.quests[4]
    quest["preQuestSingle"] = [4, *quest.get("exclusiveTo", [])]
    assert quest.get("exclusiveTo")
    nxt = load("stitch_next_ok")
    nxt["steps"] = [
        {"type": "ACCEPT", "quest": 4, "tag": "optional", "zone": "Durotar", "x": 42.1, "y": 68.3}
    ]
    assert "E_PREREQ" not in codes(validate_route(nxt, world))


def test_race_limited_steps_still_count_for_xp() -> None:
    route = load("stitch_prev")
    base = validate_route(route, build_world()).stats["xp"]["total"]
    for step in route["steps"]:
        if step["type"] == "TURNIN":
            step["races"] = ["Orc"]
    raced = validate_route(route, build_world()).stats["xp"]["total"]
    assert raced == base > 0


def test_unknown_xp_does_not_trigger_mob_level_warnings() -> None:
    route = load("stitch_prev")
    world = build_world()
    for quest in world.quests.values():
        quest.pop("xp", None)
    world.xp.clear()
    report = validate_route(route, world)
    assert not report.stats["xp"]["known"]
    assert "W_MOB_LEVEL" not in codes(report)
