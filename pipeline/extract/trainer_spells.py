"""Trainable spells per class and level for Forever, from WhatsTraining (``Classes/Camelot``).

WhatsTraining's TOC loads ``Classes\\[Game]\\<Class>.lua``. Forever's client reports the game
type ``camelot`` (the TOC gates ``ClassTrainerPlusForever`` and the Camelot weapon skills on it,
and ships ``QuestieDB_Camelot.toc``), so the Forever data is the ``Camelot`` folder, not
``Vanilla``. Each class file calls ``wt.forClass(token)`` and fills ``class.spellsByLevel``:
``{level: [{id, cost, requiredIds?}]}``. The files hold spell ids and costs only; names are
resolved by the game client at run time, so they are not available offline.

Licence: WhatsTraining is MIT (Copyright 2019). Only ids, levels and costs are read.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from pipeline.extract.game_travel import DEFAULT_ADDONS, DEFAULT_OUT, source_record
from pipeline.extract.lua_bridge import new_runtime

CLASS_DIR = Path("WhatsTraining") / "Classes" / "Camelot"
CLASS_FILES = {
    "DRUID": "Druid.lua",
    "HUNTER": "Hunter.lua",
    "MAGE": "Mage.lua",
    "PALADIN": "Paladin.lua",
    "PRIEST": "Priest.lua",
    "ROGUE": "Rogue.lua",
    "SHAMAN": "Shaman.lua",
    "WARLOCK": "Warlock.lua",
    "WARRIOR": "Warrior.lua",
}
# Forever spell ids above this are not in Classic (custom Forever spells such as 1296017).
FOREVER_CUSTOM_ID_FLOOR = 1_000_000

_LOADFILE = "function(p) local f, e = loadfile(p); if not f then error(e, 0) end; return f end"
_STUB = """
local wt = { classes = {} }
function wt.forClass(token)
  local class = { token = token }
  wt.classes[token] = class
  return class
end
return wt
"""


def read_class_file(path: Path, token: str) -> list[dict[str, Any]]:
    """Rows ``{id, level, cost, requiredIds?}`` for one class file, sorted by level then id."""
    lua = new_runtime()
    wt = lua.execute(_STUB)
    chunk = lua.eval(_LOADFILE)(str(path))
    chunk("WhatsTraining", wt)
    class_table = wt.classes[token]
    by_level = class_table.spellsByLevel
    rows: list[dict[str, Any]] = []
    for level in sorted(by_level.keys()):
        spells = by_level[level]
        for i in range(1, len(spells) + 1):
            spell = spells[i]
            row: dict[str, Any] = {
                "id": int(spell["id"]),
                "level": int(level),
                "cost": int(spell["cost"]) if spell["cost"] is not None else None,
            }
            required = spell["requiredIds"]
            if required is not None:
                row["requiredIds"] = sorted(int(required[j]) for j in range(1, len(required) + 1))
            if row["id"] >= FOREVER_CUSTOM_ID_FLOOR:
                row["foreverOnly"] = True
            rows.append(row)
    rows.sort(key=lambda r: (r["level"], r["id"]))
    return rows


def build_trainer_spells(addons: Path = DEFAULT_ADDONS) -> dict[str, Any]:
    classes = {
        token: read_class_file(addons / CLASS_DIR / filename, token)
        for token, filename in sorted(CLASS_FILES.items())
    }
    return {
        "_note": "Trainable spells by class and level (WhatsTraining Classes/Camelot = Forever). "
        "Spell names are not in the source; the client resolves them from spell ids.",
        "sources": [
            source_record(addons, CLASS_DIR / filename)
            for _token, filename in sorted(CLASS_FILES.items())
        ],
        "classes": classes,
    }


def write_trainer_spells(addons: Path = DEFAULT_ADDONS, out_dir: Path = DEFAULT_OUT) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "trainer_spells.json"
    text = json.dumps(build_trainer_spells(addons), sort_keys=True, indent=2) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")
    return path
