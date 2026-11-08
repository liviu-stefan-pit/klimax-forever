"""Curated corrections: the hand-reviewed part of the world source of truth.

File: ``data/<faction>/world/corrections.json``. Sections (all lists, all optional):

* ``equivalents``: quests that serve the same purpose on different start branches or as a
  classic id and a Forever re-implementation (phase 18 ``shadowed_ids``). The game does not make
  them exclusive, but once one is completed or active the planner should not offer the others.
  ``{"ids": [...], "name": str, "verified": bool, "source": str, "note": str}``.
* ``notDuplicates``: same-name quest ids that were reviewed and are separate quests (chain steps,
  per-race copies). They silence the graph validator's same-name check. ``{"ids", "note"}``.
* ``npcPositions``: a known-bad NPC position and its correct place. ``{"npc", "zone" (enum),
  "x", "y", "source", "note"}``. Replaces every spawn of that NPC in the compiled data.
* ``quests``: per-quest status. ``{"id", "status", "note", "source"}`` where status is
  ``broken`` (does not work on this server: never planned), ``skip`` (works, curated out) or
  ``review`` (kept, needs an in-game check).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

QUEST_STATUSES = ("broken", "review", "skip")
SECTIONS = ("equivalents", "notDuplicates", "npcPositions", "quests")


class CorrectionsError(ValueError):
    """The corrections file is malformed."""


@dataclass
class Corrections:
    equivalents: list[dict[str, Any]] = field(default_factory=list)
    not_duplicates: list[dict[str, Any]] = field(default_factory=list)
    npc_positions: list[dict[str, Any]] = field(default_factory=list)
    quests: list[dict[str, Any]] = field(default_factory=list)
    # curated spine (spine.json beside corrections.json), compiled by pipeline.world.spine
    spine: dict[str, Any] | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Corrections:
        unknown = sorted(k for k in data if not k.startswith("_") and k not in SECTIONS)
        if unknown:
            raise CorrectionsError(f"unknown section(s): {', '.join(unknown)}")
        out = cls(
            equivalents=list(data.get("equivalents", [])),
            not_duplicates=list(data.get("notDuplicates", [])),
            npc_positions=list(data.get("npcPositions", [])),
            quests=list(data.get("quests", [])),
        )
        out._check()
        return out

    @classmethod
    def load(cls, path: Path) -> Corrections:
        from pipeline.world.spine import load_spine

        out = (
            cls.from_dict(json.loads(path.read_text(encoding="utf-8")))
            if path.exists()
            else cls()
        )
        out.spine = load_spine(path.with_name("spine.json"))
        return out

    def _check(self) -> None:
        for group in (*self.equivalents, *self.not_duplicates):
            ids = group.get("ids")
            if (
                not isinstance(ids, list)
                or len(ids) < 2
                or not all(isinstance(i, int) for i in ids)
            ):
                raise CorrectionsError(f"group needs two or more integer ids: {group}")
        for row in self.quests:
            if not isinstance(row.get("id"), int) or row.get("status") not in QUEST_STATUSES:
                raise CorrectionsError(f"quest correction needs an id and a status: {row}")
        for row in self.npc_positions:
            if not isinstance(row.get("npc"), int) or not isinstance(row.get("zone"), str):
                raise CorrectionsError(f"npcPositions entry needs npc and zone: {row}")
            if not all(isinstance(row.get(k), (int, float)) for k in ("x", "y")):
                raise CorrectionsError(f"npcPositions entry needs x and y: {row}")

    # ---- lookups -----------------------------------------------------------------------------

    def quest_status(self) -> dict[int, str]:
        return {int(r["id"]): str(r["status"]) for r in self.quests}

    def equivalent_groups(self) -> list[list[int]]:
        """Sorted id lists, sorted by their first id."""
        return sorted(sorted(set(g["ids"])) for g in self.equivalents)

    def not_duplicate_groups(self) -> list[frozenset[int]]:
        return [frozenset(g["ids"]) for g in self.not_duplicates]

    def referenced_quest_ids(self) -> set[int]:
        ids = {int(r["id"]) for r in self.quests}
        for group in (*self.equivalents, *self.not_duplicates):
            ids.update(int(i) for i in group["ids"])
        return ids
