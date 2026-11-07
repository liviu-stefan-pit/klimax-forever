"""The hand-made sample route and the CLI, against the real extracted data (skipped without it)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pipeline.__main__ import main
from pipeline.routes.compile_routes import compile_faction
from pipeline.routes.validate_route import validate_route
from pipeline.routes.world import World

SAMPLE = Path("routes/horde/_sample_durotar_01-05.route.json")
HAVE_DATA = Path("data/raw/quests.json").exists() and Path("data/horde/travel.json").exists()

pytestmark = pytest.mark.skipif(not HAVE_DATA, reason="data/raw and data/horde not generated")


@pytest.fixture(scope="module")
def world() -> World:
    return World.load("horde", Path("data/raw"), Path("data"))


def test_sample_route_validates(world: World) -> None:
    route = json.loads(SAMPLE.read_text(encoding="utf-8"))
    assert route["sample"] is True
    report = validate_route(route, world)
    assert report.ok, [i.message for i in report.errors]
    assert report.stats["steps"] == len(route["steps"])


def test_sample_route_compiles(world: World, tmp_path: Path) -> None:
    result = compile_faction("horde", SAMPLE.parent, tmp_path / "Klimax", world)
    text = next(t for p, t in result.files.items() if p.name == "horde_durotar_01-05.lua")
    assert "sample = true" in text
    assert "z=1411" in text  # Durotar's uiMapID


def test_cli_validate_exit_codes(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["validate", str(SAMPLE)]) == 0
    capsys.readouterr()

    bad = json.loads(SAMPLE.read_text(encoding="utf-8"))
    bad["steps"][1]["quest"] = 99999999  # not in the DB
    path = tmp_path / "bad.route.json"
    path.write_text(json.dumps(bad), encoding="utf-8")
    assert main(["validate", str(path), "--routes-dir", str(tmp_path)]) == 1
    out = capsys.readouterr().out
    assert "step 2 ACCEPT 99999999" in out and "E_UNKNOWN_QUEST" in out


def test_cli_validate_json_output(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["validate", str(SAMPLE), "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload[0]["ok"] is True
    assert payload[0]["stats"]["steps"] > 0


def test_cli_compile_refuses_invalid_routes(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    routes = tmp_path / "routes"
    routes.mkdir()
    bad = json.loads(SAMPLE.read_text(encoding="utf-8"))
    bad["steps"][1]["x"] = 90.0  # nowhere near Kaltunk
    (routes / "bad.route.json").write_text(json.dumps(bad), encoding="utf-8")
    addon = tmp_path / "Klimax"
    code = main(["compile", "--routes-dir", str(routes), "--addon", str(addon)])
    assert code == 1
    assert not addon.exists()
    assert "compile refused" in capsys.readouterr().err
