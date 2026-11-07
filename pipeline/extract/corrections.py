"""Inventory the Forever corrections and record how the composed view is produced.

How QuestieDB composes its data (verified against the vendored copy):

* **Static** correction bodies are folded into the TOC metadata store during Generation.
  ``forever*Fixes.lua`` says so itself: "Static body stripped at package time ... this
  correction is already folded into the TOC metadata store". The baked TOC therefore *is*
  the composed Static view for Forever.
* **Dynamic** corrections depend on the running character (faction, race, class, season).
  They are applied by the client at query time and are never part of the offline view.

So this module does not re-execute Static bodies on top of the TOC (that would apply every
patch twice). It inventories each Forever-owned correction from ``src/config.lua``, checks
the file is present, and records the result in the manifest. Files that are declared but
missing from the vendored copy are listed under ``skipped`` with the reason.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

OWNED_MARK = "owned = 'Forever'"
FIELD = re.compile(r"(\w+) = (?:'([^']*)'|\{([^}]*)\}|(true|false|[\w.]+))")


@dataclass
class CorrectionReport:
    """What the corrections step found. Serialized into ``manifest.json``."""

    strategy: str = "static-folded-into-toc; dynamic-runtime-only"
    applied: list[dict[str, Any]] = field(default_factory=list)
    runtime_only: list[dict[str, Any]] = field(default_factory=list)
    skipped: list[dict[str, str]] = field(default_factory=list)

    def to_manifest(self) -> dict[str, Any]:
        """Return a JSON-ready summary with stable ordering."""
        return {
            "strategy": self.strategy,
            "applied": self.applied,
            "runtime_only": self.runtime_only,
            "skipped": self.skipped,
        }


def _parse_list(raw: str | None) -> list[str]:
    if not raw:
        return []
    return re.findall(r"'([^']*)'", raw)


def parse_owned_forever(config_text: str) -> list[dict[str, Any]]:
    """Extract the Forever-owned correction entries from ``src/config.lua``."""
    entries: list[dict[str, Any]] = []
    for line in config_text.splitlines():
        if OWNED_MARK not in line:
            continue
        entry: dict[str, Any] = {}
        for key, quoted, braced, bare in FIELD.findall(line):
            if key == "static":
                entry["static"] = _parse_list(braced)
            elif key == "dynamic":
                entry["dynamic"] = _parse_list(braced)
            elif key == "generated":
                entry["generated"] = bare == "true"
            elif key in ("file", "module", "datatype", "window", "owned"):
                entry[key] = quoted
        if "file" in entry:
            entries.append(entry)
    return entries


def inventory(questiedb: Path) -> CorrectionReport:
    """Check every Forever-owned correction against the vendored QuestieDB copy."""
    report = CorrectionReport()
    config_path = questiedb / "src" / "config.lua"
    corrections_dir = questiedb / "src" / "corrections"
    entries = parse_owned_forever(config_path.read_text(encoding="utf-8"))

    for entry in entries:
        file_rel = entry["file"]
        path = corrections_dir / file_rel
        functions = entry.get("static", [])
        record = {
            "file": file_rel,
            "datatype": entry.get("datatype"),
            "window": entry.get("window"),
        }
        if not path.is_file():
            report.skipped.append(
                {
                    "file": file_rel,
                    "error": "declared in src/config.lua but not present in the vendored QuestieDB",
                }
            )
            continue
        if entry.get("static"):
            record["static_functions"] = functions
            record["folded_into_toc"] = True
            report.applied.append(record)
        if entry.get("dynamic") or not entry.get("static"):
            dynamic = entry.get("dynamic") or []
            report.runtime_only.append({**record, "dynamic_functions": dynamic})
    report.applied.sort(key=lambda item: item["file"])
    report.runtime_only.sort(key=lambda item: item["file"])
    report.skipped.sort(key=lambda item: item["file"])
    return report


OBJECTIVE_HINT = re.compile(
    r"^QuestieCorrections\.(\w*ObjectiveFirst)\[(\d+)\]\s*=\s*true", re.MULTILINE
)


def objective_hints(questiedb: Path) -> dict[str, list[int]]:
    """Top-level ``QuestieCorrections.<kind>ObjectiveFirst[id] = true`` hints.

    QuestieDB runs these at load time, outside ``Load()``, so they are not in the TOC. They
    decide which objective of a quest comes first. Only unconditional, column-0 assignments
    are read; that is what the Forever files contain.
    """
    root = questiedb / "src" / "corrections" / "Forever"
    hints: dict[str, set[int]] = {}
    for path in sorted(root.rglob("*.lua")):
        for kind, quest_id in OBJECTIVE_HINT.findall(path.read_text(encoding="utf-8")):
            hints.setdefault(kind, set()).add(int(quest_id))
    return {kind: sorted(ids) for kind, ids in sorted(hints.items())}
