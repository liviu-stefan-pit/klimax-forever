"""Classic player XP needed to advance from level L to L+1.

Source: the Classic (1.12) player experience table, as published on Wowpedia
("Experience point" / "Level" pages) and on the Vanilla WoW wiki. The vendored QuestieDB copy
has no player XP table (``support/Forever/QuestXP`` only holds per-quest XP), so these numbers
were entered by hand. They are used only to size a band's ``xpBudget``; spot-check them against
the Forever client before relying on them for anything stricter.
"""

from __future__ import annotations

# XP_TO_NEXT[L] = XP needed to go from level L to level L + 1 (L = 1..59).
XP_TO_NEXT: dict[int, int] = {
    1: 400, 2: 900, 3: 1400, 4: 2100, 5: 2800, 6: 3600, 7: 4500, 8: 5400, 9: 6500,
    10: 7600, 11: 8800, 12: 10100, 13: 11400, 14: 12900, 15: 14400, 16: 16000,
    17: 17700, 18: 19400, 19: 21300, 20: 23200, 21: 25200, 22: 27300, 23: 29400,
    24: 31700, 25: 34000, 26: 36400, 27: 38900, 28: 41400, 29: 44300, 30: 47400,
    31: 50800, 32: 54500, 33: 58600, 34: 62800, 35: 67100, 36: 71600, 37: 76100,
    38: 80800, 39: 85700, 40: 90700, 41: 95800, 42: 101000, 43: 106300, 44: 111800,
    45: 117500, 46: 123200, 47: 129100, 48: 135100, 49: 141200, 50: 147500,
    51: 153900, 52: 160400, 53: 167100, 54: 173900, 55: 180800, 56: 187900,
    57: 195000, 58: 202300, 59: 209800,
}  # fmt: skip


def xp_for_levels(lo: int, hi: int) -> int:
    """Total XP needed to climb from level ``lo`` to level ``hi``."""
    return sum(XP_TO_NEXT[level] for level in range(lo, hi))
