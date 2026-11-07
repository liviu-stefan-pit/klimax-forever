"""Phase 01 tests: the QuestieDB extractor against the vendored copy.

These tests need the local ``QuestieDB/`` folder (git-ignored input). They are skipped when it
is absent, so a fresh clone without the input still runs the rest of the suite.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pipeline.extract.decode_toc import decode_ids, stream_toc
from pipeline.extract.run import DEFAULT_QUESTIEDB, run_extract
from pipeline.extract.schema import load_schemas

pytestmark = pytest.mark.skipif(
    not (DEFAULT_QUESTIEDB / "QuestieDB_Forever.toc").is_file(),
    reason="QuestieDB/ is not present (local input, not committed)",
)


@pytest.fixture(scope="module")
def extract_once(tmp_path_factory: pytest.TempPathFactory) -> Path:
    out = tmp_path_factory.mktemp("raw_run1")
    run_extract(out_dir=out)
    return out


@pytest.fixture(scope="module")
def quests(extract_once: Path) -> dict[str, dict]:
    return json.loads((extract_once / "quests.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def npcs(extract_once: Path) -> dict[str, dict]:
    return json.loads((extract_once / "npcs.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def items(extract_once: Path) -> dict[str, dict]:
    return json.loads((extract_once / "items.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize(
    ("quest_id", "expected_name"),
    [
        ("7", "Kobold Camp Cleanup"),
        ("6", "Bounty on Garrick Padfoot"),
        ("5", "Jitters' Growling Gut"),
        ("2", "Sharptalon's Claw"),
    ],
)
def test_known_quest_names(quests: dict[str, dict], quest_id: str, expected_name: str) -> None:
    assert quests[quest_id]["name"] == expected_name


def test_quest_seven_objective_mentions_kobold_vermin(quests: dict[str, dict]) -> None:
    lines = quests["7"]["objectivesText"]
    assert any("Kobold Vermin" in line for line in lines)


def test_id_counts_match_ids_header(
    quests: dict[str, dict], npcs: dict[str, dict], items: dict[str, dict]
) -> None:
    questiedb = DEFAULT_QUESTIEDB
    schemas = load_schemas(questiedb, lambda _path: "")
    store = stream_toc(questiedb / "QuestieDB_Forever.toc")
    for entity, decoded in (("Quest", quests), ("Npc", npcs), ("Item", items)):
        header_ids = decode_ids(store, schemas[entity]).ids
        assert len(header_ids) == len(decoded), entity
        assert {str(i) for i in header_ids} == set(decoded), entity


def test_known_npc_spawns_are_valid_percentages(npcs: dict[str, dict]) -> None:
    # Marshal McBride (197) gives quest 7; his spawn points must be real map percentages.
    spawns = npcs["197"]["spawns"]
    assert spawns, "expected spawn data for Marshal McBride"
    for rows in spawns.values():
        for row in rows:
            x, y = row[0], row[1]
            # [-1, -1] is QuestieDB's instance sentinel, not a map position.
            assert (x, y) == (-1, -1) or (0 <= x <= 100 and 0 <= y <= 100)


def test_quest_reward_inverse(quests: dict[str, dict], items: dict[str, dict]) -> None:
    pair = next(
        (
            (int(item_id), int(quest_id))
            for item_id, record in items.items()
            for quest_id in record.get("questRewards", [])
        ),
        None,
    )
    assert pair is not None, "no item lists a quest reward"
    item_id, quest_id = pair
    assert item_id in quests[str(quest_id)]["rewardItemIds"]


def test_outputs_have_sorted_keys_and_manifest(extract_once: Path) -> None:
    manifest = json.loads((extract_once / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["questiedb"]["version"] == "1.0.11"
    assert manifest["questiedb"]["contract_version"] == "4"
    assert manifest["compression"]["used"]["Quest"] == "zlib"
    for name in ("quests.json", "npcs.json", "items.json", "objects.json", "xp.json", "zones.json"):
        assert name in manifest["outputs"]
        assert len(manifest["outputs"][name]["sha256"]) == 64


def test_running_twice_is_byte_identical(tmp_path: Path, extract_once: Path) -> None:
    second = tmp_path / "raw_run2"
    run_extract(out_dir=second)
    for path in sorted(extract_once.iterdir()):
        assert (second / path.name).read_bytes() == path.read_bytes(), path.name


def test_objective_hints_match_forever_files(extract_once: Path) -> None:
    hints = json.loads((extract_once / "objective_hints.json").read_text(encoding="utf-8"))
    assert hints["itemObjectiveFirst"] == [503, 5088, 91317, 92682, 97277, 97485]
    assert hints["killCreditObjectiveFirst"] == [94489, 98386]
