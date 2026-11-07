"""Quest ids and step order from RXPGuides' Forever Horde guides (read-only cross-check).

RXPGuides is not open source (Creative Commons BY-NC-SA 4.0 per its LICENSE file), so this
module keeps **only numeric quest ids, the action kind (accept / turnin / complete), a step
counter and a "has a class/race condition" bit**. No guide text, coordinates or notes are read
into the result, and the output stays under ``data/raw/game/`` (git-ignored).
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from pipeline.extract.game_travel import DEFAULT_ADDONS, DEFAULT_OUT, source_record

GUIDE_DIR = Path("RXPGuides") / "Guides" / "forever"
# File -> start branch (shape track) the guide leads. Shared guides feed every branch.
GUIDE_FILES: dict[str, str] = {
    "Horde-01-12_Durotar.lua": "durotar",
    "Horde-01-14_Undead.lua": "tirisfal",
    "Horde-1-12_Mulgore.lua": "mulgore",
    "Horde-12-22_Barrens.lua": "horde",
    "Horde-Mage-12-21.lua": "horde",
}

_ACTION = re.compile(r"^\s*\.(accept|turnin|complete)\s+(\d+)")
_STEP = re.compile(r"^\s*step\b")
_GUIDE_START = "RXPGuides.RegisterGuide("


def parse_guide_text(text: str) -> list[dict[str, Any]]:
    """Guides found in one file: ``[{"index": n, "steps": [[step, action, quest, cond]]}]``.

    Comment lines (``--``) are skipped. ``cond`` is true when the line carries a ``<<`` class or
    race condition. Guide names are deliberately not kept; guides are numbered in file order.
    """
    guides: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    step = 0
    for line in text.splitlines():
        if _GUIDE_START in line:
            current = {"index": len(guides) + 1, "steps": []}
            guides.append(current)
            step = 0
            continue
        if current is None or line.lstrip().startswith("--"):
            continue
        if _STEP.match(line):
            step += 1
            continue
        match = _ACTION.match(line)
        if match:
            current["steps"].append([step, match.group(1), int(match.group(2)), "<<" in line])
    return guides


def build_rxp_quest_ids(addons: Path = DEFAULT_ADDONS) -> dict[str, Any]:
    files: dict[str, Any] = {}
    for name, branch in sorted(GUIDE_FILES.items()):
        text = (addons / GUIDE_DIR / name).read_text(encoding="utf-8", errors="replace")
        files[name] = {"branch": branch, "guides": parse_guide_text(text)}
    return {
        "_note": "Quest ids and step order only. Cross-check input; never merged into route data.",
        "sources": [source_record(addons, GUIDE_DIR / name) for name in sorted(GUIDE_FILES)],
        "files": files,
    }


def write_rxp_quest_ids(addons: Path = DEFAULT_ADDONS, out_dir: Path = DEFAULT_OUT) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "rxp_quest_ids.json"
    text = json.dumps(build_rxp_quest_ids(addons), sort_keys=True, indent=1) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")
    return path
