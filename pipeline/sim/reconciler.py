"""Python port of the quest-state reconciler (``Klimax/State/Reconciler.lua``), the part the
simulator needs: gates, completion (also implied by later links and equivalents), the log, skips.

The simulator feeds it a snapshot ``{level, race, raceToken, class, log, completed, skipped, seen,
broken}`` and quest lookups, and asks :meth:`Reconciler.state` for ``(state, reason)`` exactly like
``K.State:Get`` would.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

RACE_BITS = {
    "Human": 1,
    "Orc": 2,
    "Dwarf": 4,
    "NightElf": 8,
    "Undead": 16,
    "Scourge": 16,
    "Tauren": 32,
    "Gnome": 64,
    "Troll": 128,
}
CLASS_BITS = {
    "WARRIOR": 1,
    "PALADIN": 2,
    "HUNTER": 4,
    "ROGUE": 8,
    "PRIEST": 16,
    "SHAMAN": 64,
    "MAGE": 128,
    "WARLOCK": 256,
    "DRUID": 1024,
}


def has_bit(mask: int | None, bit: int | None) -> bool:
    if not mask or not bit:
        return True
    return (mask // bit) % 2 == 1


class Reconciler:
    def __init__(
        self,
        snap: dict[str, Any],
        info: Callable[[int], dict[str, Any] | None],
        ex_group: Callable[[int], list[int] | None],
        eq_group: Callable[[int], list[int] | None],
    ) -> None:
        self.snap = snap
        self.info = info
        self.ex_group = ex_group
        self.eq_group = eq_group
        self._memo: dict[int, tuple[str, str | None]] = {}
        self._implied: set[int] | None = None

    def implied(self) -> set[int]:
        if self._implied is not None:
            return self._implied
        out: set[int] = set()
        stack = [q for q, v in self.snap.get("completed", {}).items() if v]
        while stack:
            q = stack.pop()
            rec = self.info(q)
            if rec:
                for lst in (rec.get("pv") or [], rec.get("pa") or []):
                    for p in lst:
                        if p not in out:
                            out.add(p)
                            stack.append(p)
        self._implied = out
        return out

    def completed(self, q: int) -> bool:
        done = self.snap.get("completed", {})
        if done.get(q):
            return True
        for other in self.eq_group(q) or []:
            if done.get(other):
                return True
        return q in self.implied()

    def _prereq_met(self, p: int) -> bool:
        return self.completed(p) or self.snap.get("completedKnown") is not True

    def gate(self, q: int, rec: dict[str, Any] | None) -> str | None:
        if not rec:
            return None
        snap = self.snap
        if rec.get("ra") and snap.get("race"):
            bit = RACE_BITS.get(snap.get("raceToken") or "") or RACE_BITS.get(snap["race"])
            if bit and not has_bit(rec["ra"], bit):
                return "race"
        if rec.get("cl") and snap.get("class"):
            bit = CLASS_BITS.get(snap["class"])
            if bit and not has_bit(rec["cl"], bit):
                return "class"
        need = max(rec.get("re") or 0, rec.get("rl") or 0)
        level = snap.get("level")
        if level and need > level:
            return "level"
        if rec.get("mx") and level and level > rec["mx"]:
            return "maxlevel"
        if rec.get("ex"):
            for other in self.ex_group(rec["ex"]) or []:
                if other != q and (self.completed(other) or other in (snap.get("log") or {})):
                    return "exclusive"
        for p in rec.get("pa") or []:
            if not self._prereq_met(p):
                return "prereq"
        po = rec.get("po") or []
        if po and not any(self._prereq_met(p) for p in po):
            return "prereq"
        return None

    def _compute(self, q: int) -> tuple[str, str | None]:
        snap = self.snap
        rec = self.info(q)
        if rec and rec.get("cx") == "broken":
            return "broken", "curated"
        if (snap.get("broken") or {}).get(q):
            return "broken", "reported"
        if self.completed(q):
            return "completed", None
        entry = (snap.get("log") or {}).get(q)
        if entry:
            if entry.get("failed"):
                return "failed", None
            return ("objectives-done" if entry.get("complete") else "active"), None
        if (snap.get("skipped") or {}).get(q):
            return "ignored", "skipped"
        if rec and rec.get("cx") == "skip":
            return "ignored", "curated"
        gate = self.gate(q, rec)
        if (snap.get("seen") or {}).get(q) and not gate:
            return "abandoned", None
        if gate:
            return "unavailable", gate
        return "available", None

    def state(self, q: int) -> tuple[str, str | None]:
        got = self._memo.get(q)
        if got is None:
            got = self._compute(q)
            self._memo[q] = got
        return got
