"""Quest flags (PRD §5.5) and the heuristics behind them.

Heuristics (also listed in docs/PROGRESS.md):

* ``elite``      a direct creature objective with rank 1, 2 or 3 (elite, rare-elite, boss), or an
                 item objective whose *easiest* drop source is elite. Rank 4 (rare) is not elite.
* ``group``      questFlags RAID bit (64), objective text mentioning a group/party/N-man, or a
                 rank 2/3 creature objective (rare-elite or boss).
* ``escort``     "escort"/"accompany"/"journey" in the quest name or text, or the PARTY_ACCEPT
                 questFlag (2) + specialFlags bit 2 (the DB's "scripted event" marker, which also
                 covers dances and waits) together with protect/follow/lead/rescue wording.
* ``dungeon``    any objective cluster, or the quest's own zone, lies in ``dungeons.lua``.
* ``profession`` has ``requiredSkill``.
* ``rep``        has ``requiredMinRep``.
* ``breadcrumb`` ``breadcrumbForQuestId`` is set (this quest leads into another one).
* ``chainHead``  no prerequisites, has a follow-up (``nextQuestInChain`` / ``childQuests``) and
                 somewhere down that chain (depth <= 8) a quest rewards a bag or an upgrade.
* ``class:<T>``  ``requiredClasses`` bit(s), one tag per class token.
"""

from __future__ import annotations

import re
from typing import Any

from pipeline.shape.factions import CLASS_BITS

QUEST_FLAG_PARTY_ACCEPT = 2
QUEST_FLAG_RAID = 64
SPECIAL_FLAG_EVENT = 2

ELITE_RANKS = frozenset({1, 2, 3})
BOSS_RANKS = frozenset({2, 3})

_GROUP_RE = re.compile(r"\b(group|party|\d+[- ]?(?:man|player)s?)\b", re.IGNORECASE)
_ESCORT_RE = re.compile(r"\b(escort\w*|accompany\w*|journey)\b", re.IGNORECASE)
_EVENT_ESCORT_RE = re.compile(
    r"\b(protect\w*|defend\w*|follow\w*|go with|lead\w*|guide\w*|rescue\w*|show \w+ the way)\b",
    re.IGNORECASE,
)

CHAIN_DEPTH = 8


def class_tokens(mask: int) -> list[str]:
    """Class tokens for a ``requiredClasses`` bitmask. Unknown bits become ``BIT<n>``."""
    tokens = [token for token, bit in CLASS_BITS.items() if mask & bit]
    known = 0
    for bit in CLASS_BITS.values():
        known |= bit
    rest = mask & ~known
    shift = 0
    while rest:
        if rest & 1:
            tokens.append(f"BIT{shift}")
        rest >>= 1
        shift += 1
    return sorted(tokens)


def is_group(quest: dict[str, Any], objective_ranks: list[int]) -> bool:
    if quest.get("questFlags", 0) & QUEST_FLAG_RAID:
        return True
    text = " ".join(quest.get("objectivesText") or [])
    if _GROUP_RE.search(text):
        return True
    return any(rank in BOSS_RANKS for rank in objective_ranks)


def is_escort(quest: dict[str, Any]) -> bool:
    text = quest.get("name", "") + " " + " ".join(quest.get("objectivesText") or [])
    if _ESCORT_RE.search(text):
        return True
    return bool(
        quest.get("questFlags", 0) & QUEST_FLAG_PARTY_ACCEPT
        and quest.get("specialFlags", 0) & SPECIAL_FLAG_EVENT
        and _EVENT_ESCORT_RE.search(text)
    )


def has_prereqs(quest: dict[str, Any]) -> bool:
    return bool(
        quest.get("preQuestGroup") or quest.get("preQuestSingle") or quest.get("parentQuest")
    )


def chain_members(
    quests: dict[int, dict[str, Any]], head: int, depth: int = CHAIN_DEPTH
) -> list[int]:
    """Quest ids reachable from ``head`` via nextQuestInChain / childQuests (BFS, bounded)."""
    seen = {head}
    order: list[int] = []
    frontier = [head]
    for _ in range(depth):
        nxt: list[int] = []
        for qid in frontier:
            quest = quests.get(qid)
            if not quest:
                continue
            for child in [quest.get("nextQuestInChain", 0), *(quest.get("childQuests") or [])]:
                if child and child not in seen and child in quests:
                    seen.add(child)
                    order.append(child)
                    nxt.append(child)
        frontier = nxt
    return order
