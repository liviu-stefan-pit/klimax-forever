"""Turn a ``/klimax dump`` (Klimax SavedVariables) into a JSON save-state fixture.

The add-on stores one snapshot per character in ``KlimaxDB.dumps["Name-Realm"]`` (see
``Klimax/Diag.lua``). ``fixture_from_dump`` normalises it for the busted fixture loader
(``tests/lua/fixture.lua``): list fields are always lists, quest id lists are sorted, numeric
table keys become strings, and the character's name and realm are dropped unless asked for.
``write_fixture`` writes sorted, indented JSON so a fixture diffs cleanly.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from pipeline.diagnose.savedvars import parse_savedvariables

FIXTURE_SCHEMA = 1
DEFAULT_FIXTURE_DIR = Path("tests/fixtures")

# Snapshot fields that are lists (an empty Lua table is read as {} and must become []).
_LIST_FIELDS = ("questLog", "completed", "completedSet", "disagreements", "debugLog")
_ENGINE_LIST_FIELDS = ("markLog",)


class FixtureError(ValueError):
    """The SavedVariables file has no usable dump."""


def _as_list(value: Any) -> list[Any]:
    if value is None or value == {}:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [value[k] for k in sorted(value, key=lambda k: (str(type(k)), k))]
    return [value]


def _json_keys(value: Any) -> Any:
    """Recursively turn int dict keys into strings (JSON object keys)."""
    if isinstance(value, dict):
        return {str(k): _json_keys(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_json_keys(v) for v in value]
    return value


def select_dump(saved: dict[str, Any], char: str | None = None) -> tuple[str, dict[str, Any]]:
    """Pick one character's dump from parsed SavedVariables. Returns (key, dump)."""
    db = saved.get("KlimaxDB")
    dumps = db.get("dumps") if isinstance(db, dict) else None
    if not isinstance(dumps, dict) or not dumps:
        raise FixtureError("no KlimaxDB.dumps in this file: run /klimax dump in game, then /reload")
    if char is not None:
        if char not in dumps:
            raise FixtureError(f"no dump for {char!r}; found: {', '.join(sorted(dumps))}")
        return char, dumps[char]
    if len(dumps) > 1:
        raise FixtureError(f"several dumps, pick one with --char: {', '.join(sorted(dumps))}")
    key = next(iter(dumps))
    return key, dumps[key]


def fixture_from_dump(
    dump: dict[str, Any], *, source: str = "", keep_name: bool = False
) -> dict[str, Any]:
    """A normalised fixture dict from one character's dump."""
    if not isinstance(dump, dict) or "player" not in dump:
        raise FixtureError("the dump has no player block")
    out: dict[str, Any] = {k: v for k, v in dump.items()}
    for name in _LIST_FIELDS:
        if name in out or name in ("questLog", "completed"):
            out[name] = _as_list(out.get(name))
    out["completed"] = sorted({int(q) for q in out["completed"]})
    if "completedSet" in out:
        out["completedSet"] = sorted({int(q) for q in out["completedSet"]})
    for line in out["questLog"]:
        if isinstance(line, dict) and "objectives" in line:
            line["objectives"] = _as_list(line["objectives"])
    engine = dict(out.get("engine") or {})
    for name in _ENGINE_LIST_FIELDS:
        if name in engine:
            engine[name] = _as_list(engine[name])
    out["engine"] = engine
    player = dict(out["player"])
    if not keep_name:
        player.pop("name", None)
        player.pop("realm", None)
    out["player"] = player
    out["schema"] = FIXTURE_SCHEMA
    out["synthetic"] = False
    if source:
        out["source"] = source
    return _json_keys(out)


def default_name(fixture: dict[str, Any]) -> str:
    """A file stem like ``hunter15_orc`` from the fixture's player block."""
    p = fixture.get("player", {})
    parts = [str(p.get("class", "char")).lower() + str(p.get("level", "")), str(p.get("race", ""))]
    stem = "_".join(x for x in parts if x).lower()
    return re.sub(r"[^a-z0-9_]+", "", stem) or "fixture"


def dumps_fixture(fixture: dict[str, Any]) -> str:
    return json.dumps(fixture, indent=1, sort_keys=True, ensure_ascii=False) + "\n"


def convert_file(
    savedvars: Path,
    out: Path | None = None,
    *,
    char: str | None = None,
    keep_name: bool = False,
    out_dir: Path = DEFAULT_FIXTURE_DIR,
) -> Path:
    """Read a SavedVariables file, write the fixture JSON and return its path."""
    saved = parse_savedvariables(savedvars.read_text(encoding="utf-8", errors="replace"))
    _key, dump = select_dump(saved, char)
    fixture = fixture_from_dump(dump, source=savedvars.name, keep_name=keep_name)
    target = out or out_dir / f"{default_name(fixture)}.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(dumps_fixture(fixture), encoding="utf-8", newline="\n")
    return target
