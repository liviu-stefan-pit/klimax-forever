"""Phase 18: SavedVariables parser, dump-to-fixture converter and the offline data checks."""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

import pytest

from pipeline.__main__ import main
from pipeline.diagnose import data_checks as dc
from pipeline.diagnose.fixture import (
    FixtureError,
    convert_file,
    default_name,
    fixture_from_dump,
    select_dump,
)
from pipeline.diagnose.savedvars import SavedVariablesError, parse_savedvariables
from pipeline.routes.world import World
from pipeline.tests.routes.helpers import build_world

REPO = Path(__file__).resolve().parents[2]

# What the client writes for KlimaxDB after `/klimax dump` (shape of Klimax/Diag.lua Snapshot).
SAVED = r"""
KlimaxDB = {
	["version"] = 1,
	["options"] = {
	},
	["dumps"] = {
		["Tester-Forever"] = {
			["schema"] = 1,
			["addon"] = "0.7.0",
			["engineMode"] = "legacy",
			["player"] = {
				["name"] = "Tester",
				["realm"] = "Forever",
				["class"] = "HUNTER",
				["race"] = "Orc",
				["raceToken"] = "Orc",
				["faction"] = "Horde",
				["level"] = 15,
				["xp"] = 4200,
				["xpMax"] = 10600,
			},
			["position"] = {
				["mapID"] = 1413,
				["x"] = 0.523,
				["y"] = 0.305,
				["zone"] = "The Barrens",
				["subzone"] = "The \"Crossroads\"",
			},
			["api"] = {
				["completed"] = "global",
				["questLog"] = "classic",
				["numQuests"] = 2,
				["hiddenQuests"] = 0,
			},
			["questLog"] = {
				{
					["index"] = 1,
					["title"] = "The Barrens",
					["header"] = true,
					["collapsed"] = false,
				}, -- [1]
				{
					["index"] = 2,
					["title"] = "Apothecary Zamah",
					["questID"] = 853,
					["complete"] = -1,
					["level"] = 15,
					["header"] = false,
					["collapsed"] = false,
					["objectives"] = {
					},
				}, -- [2]
			},
			["completed"] = {
				870, -- [1]
				845, -- [2]
				870, -- [3]
			},
			["completedKnown"] = true,
			["engine"] = {
				["routeId"] = "horde_horde_10-15",
				["stepState"] = {
					["horde_horde_10-15"] = {
						["horde_horde_10-15:A:872:0"] = "done",
					},
				},
				["ignoredSuggestions"] = {
					[744] = true,
				},
				["markLog"] = {
				},
			},
			["disagreements"] = {
			},
		},
	},
}
KlimaxCharDB = nil
"""


# ---- SavedVariables parser -------------------------------------------------------------------


def test_parses_nested_tables_arrays_and_scalars() -> None:
    data = parse_savedvariables(SAVED)
    dump = data["KlimaxDB"]["dumps"]["Tester-Forever"]
    assert data["KlimaxDB"]["options"] == {}
    assert "KlimaxCharDB" in data and data["KlimaxCharDB"] is None
    assert dump["player"]["level"] == 15
    assert dump["position"]["x"] == pytest.approx(0.523)
    assert dump["position"]["subzone"] == 'The "Crossroads"'
    assert dump["questLog"][1]["complete"] == -1
    assert dump["questLog"][0]["header"] is True
    assert dump["completed"] == [870, 845, 870]
    assert dump["engine"]["ignoredSuggestions"] == {744: True}


def test_parses_escapes_numbers_and_bare_keys() -> None:
    text = 'X = { a = "l1\\nl2\\t\\65", b = -1.5e2, c = 0x1F, [2] = false, ["k"] = \'q\' }'
    x = parse_savedvariables(text)["X"]
    assert x == {"a": "l1\nl2\tA", "b": -150.0, "c": 31, 2: False, "k": "q"}


def test_mixed_and_sparse_integer_keys_stay_dicts() -> None:
    x = parse_savedvariables("X = { [1] = 'a', [3] = 'c' }")["X"]
    assert x == {1: "a", 3: "c"}
    assert parse_savedvariables("X = { 'a', 'b' }")["X"] == ["a", "b"]


def test_bad_input_raises_with_a_line_number() -> None:
    with pytest.raises(SavedVariablesError, match="line 2"):
        parse_savedvariables('X = {\n ["a"] = }')
    with pytest.raises(SavedVariablesError):
        parse_savedvariables('X = "open')


# ---- fixture converter -----------------------------------------------------------------------


def test_select_dump_by_default_by_key_and_errors() -> None:
    saved = parse_savedvariables(SAVED)
    key, dump = select_dump(saved)
    assert key == "Tester-Forever" and dump["schema"] == 1
    assert select_dump(saved, "Tester-Forever")[0] == "Tester-Forever"
    with pytest.raises(FixtureError, match="no dump for"):
        select_dump(saved, "Other-Forever")
    two = copy.deepcopy(saved)
    two["KlimaxDB"]["dumps"]["Alt-Forever"] = dump
    with pytest.raises(FixtureError, match="--char"):
        select_dump(two)
    with pytest.raises(FixtureError, match="/klimax dump"):
        select_dump({"KlimaxDB": {"options": {}}})


def test_fixture_normalises_lists_ids_keys_and_privacy() -> None:
    _key, dump = select_dump(parse_savedvariables(SAVED))
    fx = fixture_from_dump(dump, source="Klimax.lua")
    assert "name" not in fx["player"] and "realm" not in fx["player"]
    assert fx["completed"] == [845, 870]
    assert fx["questLog"][1]["objectives"] == []
    assert fx["disagreements"] == []
    assert fx["engine"]["markLog"] == []
    assert fx["engine"]["ignoredSuggestions"] == {"744": True}
    assert fx["synthetic"] is False and fx["source"] == "Klimax.lua"
    assert default_name(fx) == "hunter15_orc"
    kept = fixture_from_dump(dump, keep_name=True)
    assert kept["player"]["name"] == "Tester"


def test_convert_file_is_deterministic(tmp_path: Path) -> None:
    src = tmp_path / "Klimax.lua"
    src.write_text(SAVED, encoding="utf-8")
    out = convert_file(src, out_dir=tmp_path / "fx")
    assert out.name == "hunter15_orc.json"
    first = out.read_bytes()
    convert_file(src, out)
    assert out.read_bytes() == first
    data = json.loads(first)
    assert list(data) == sorted(data)
    assert data["engine"]["stepState"]["horde_horde_10-15"]["horde_horde_10-15:A:872:0"] == "done"


def test_cli_fixture(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    src = tmp_path / "Klimax.lua"
    src.write_text(SAVED, encoding="utf-8")
    out = tmp_path / "x.json"
    assert main(["fixture", str(src), "--out", str(out)]) == 0
    assert out.exists() and "wrote" in capsys.readouterr().out
    bad = tmp_path / "bad.lua"
    bad.write_text("KlimaxDB = { }", encoding="utf-8")
    assert main(["fixture", str(bad)]) == 1
    assert "/klimax dump" in capsys.readouterr().err


def test_synthetic_hunter_fixture_has_the_loader_fields() -> None:
    fx = json.loads((REPO / "tests/fixtures/hunter15_synthetic.json").read_text(encoding="utf-8"))
    assert fx["synthetic"] is True
    for key in ("player", "position", "api", "questLog", "completed", "engine"):
        assert key in fx
    assert fx["player"]["class"] == "HUNTER" and fx["player"]["level"] == 15
    assert fx["completed"] == sorted(fx["completed"])
    assert fx["engine"]["routeId"] in fx["engine"]["stepState"]


# ---- data checks -----------------------------------------------------------------------------


def _step(kind: str, quest: int | None = None, **extra: Any) -> dict[str, Any]:
    step: dict[str, Any] = {"type": kind, "zone": "Durotar", "x": 42.1, "y": 68.3}
    if quest is not None:
        step["quest"] = quest
    step.update(extra)
    return step


def _route(rid: str, branch: str, lo: int, steps: list[dict[str, Any]], nxt: str | None = None):
    route: dict[str, Any] = {"id": rid, "branch": branch, "band": [lo, lo + 5], "steps": steps}
    if nxt:
        route["next"] = nxt
    return route


@pytest.fixture()
def world() -> World:
    w = build_world()
    w.quests[90002] = dict(w.quests[2], name="Second Steps")
    return w


@pytest.fixture()
def routes() -> dict[str, dict[str, Any]]:
    durotar = [
        _step("ACCEPT", 1, npc=100, x=43.29, y=68.53),
        _step("TURNIN", 1, npc=101),
        _step("TURNIN", 2, npc=101),  # no ACCEPT before it
        _step("ACCEPT", 9, npc=101, classes=["WARRIOR"]),
        _step("TURNIN", 9, npc=101),  # applies to every class, the ACCEPT only to warriors
        _step("TURNIN", 1, npc=101),  # second turn-in of 1
        _step("ACCEPT", 8, npc=999),  # NPC not in the DB
        _step("TRAVEL", zone="The Barrens", x=52.0, y=30.0),
        _step("TURNIN", 8, npc=101, zone="Durotar", x=60.0, y=10.0),  # Gornek elsewhere
        _step("TRAVEL", zone="Durotar", x=50.0, y=50.0),
    ]
    mulgore = [
        _step("ACCEPT", 11, npc=101),
        _step("TURNIN", 11, npc=101, reward={"preferItem": 5, "why": "x"}),
        _step("TURNIN", 3, npc=101, races=["Tauren"], reward={"preferItem": 6, "why": "y"}),
    ]
    return {
        "horde_durotar_01-05": _route("horde_durotar_01-05", "durotar", 1, durotar),
        "horde_mulgore_01-05": _route("horde_mulgore_01-05", "mulgore", 1, mulgore),
    }


def test_branch_paths_follow_next(world: World, routes: dict[str, dict[str, Any]]) -> None:
    routes["horde_durotar_01-05"]["next"] = "horde_horde_10-15"
    routes["horde_horde_10-15"] = _route("horde_horde_10-15", "horde", 10, [])
    paths = dc.branch_paths(routes, world)
    assert paths["durotar"] == ["horde_durotar_01-05", "horde_horde_10-15"]
    assert paths["mulgore"] == ["horde_mulgore_01-05"]


def test_scope_gaps(world: World, routes: dict[str, dict[str, Any]]) -> None:
    found = {(f["step"], f["problem"]): f for f in dc.scope_gaps(routes, world)}
    assert (2, "no-accept-before") in found
    gap9 = found[(4, "no-accept-before")]
    assert "Orc/HUNTER" in gap9["who"] or any("more" in w for w in gap9["who"])
    assert all("WARRIOR" not in w for w in gap9["who"])
    assert (5, "turned-in-twice") in found
    assert dc.scope_gaps(routes, world) == dc.scope_gaps(routes, world)


def test_npc_positions(world: World, routes: dict[str, dict[str, Any]]) -> None:
    world.npcs[101]["spawns"] = {"14": [[42.06, 68.33], [70.0, 20.0]]}
    world.npcs[102] = {"name": "Ghost", "spawns": {}}
    routes["horde_mulgore_01-05"]["steps"].append(_step("ACCEPT", 10, npc=102))
    problems = {(f["route"], f["step"], f["problem"]) for f in dc.npc_positions(routes, world)}
    assert ("horde_durotar_01-05", 6, "npc-not-in-db") in problems
    assert ("horde_mulgore_01-05", 3, "npc-no-spawns") in problems
    assert ("horde_durotar_01-05", 1, "spawns-far-apart") in problems
    assert ("horde_durotar_01-05", 8, "npc-placed-differently") in problems


def test_shadowed_ids(world: World, routes: dict[str, dict[str, Any]]) -> None:
    found = dc.shadowed_ids(routes, world)
    assert found == [
        {
            "name": "Second Steps",
            "ids": [2, 90002],
            "inRoutes": [2],
            "kind": "classic-and-custom",
        }
    ]


def test_cross_branch_rewards(world: World, routes: dict[str, dict[str, Any]]) -> None:
    found = dc.cross_branch_rewards(routes, world)
    durotar = [f for f in found if f["branch"] == "durotar"]
    assert [(f["route"], f["quest"], f["races"]) for f in durotar] == [
        ("horde_mulgore_01-05", 11, ["Orc", "Troll"])
    ]
    assert not [f for f in found if f["branch"] == "mulgore"]


def test_zone_flow(world: World, routes: dict[str, dict[str, Any]]) -> None:
    flow = {f["route"]: f for f in dc.zone_flow(routes, world)}
    d = flow["horde_durotar_01-05"]
    assert d["order"] == ["Durotar", "The Barrens", "Durotar"]
    assert (d["changes"], d["returns"], d["zones"]) == (2, 1, 2)
    as_char = dc.run_checks(routes, world, ["zone_flow"], ("Orc", "HUNTER"))
    assert list(as_char) == ["zone_flow"]


def test_run_checks_and_report(world: World, routes: dict[str, dict[str, Any]]) -> None:
    results = dc.run_checks(routes, world)
    assert list(results) == list(dc.CHECKS)
    text = dc.format_report(results, limit=1)
    assert "== scope_gaps:" in text and "more (use --json for all)" in text
