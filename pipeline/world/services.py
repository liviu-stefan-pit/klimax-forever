"""Service roles (vendors, trainers, inns, flight masters, banks, auction house, mail ...).

Roles come from the data the travel graph already uses (``game_merge.py`` and ``shape/travel.py``):

* ``npcFlags`` (Classic/Forever bits, QuestieDB ``corrections/enum/expansions.lua``): vendor 4,
  flight master 8, trainer 16, innkeeper 128, banker 256, auctioneer 4096, stable master 8192,
  repair 16384;
* ``subName`` for the kind of trainer (class, profession, pet, weapon master) and for reagent and
  poison vendors and zeppelin masters;
* ``items.vendors`` (the inverse vendor map) for food, water, arrows, bullets and bags. This DB
  stores food and drink as consumables with subclass 0 (the shape step's subclass 5 test finds
  almost none), so food and water are the staple consumables: sold by at least
  ``STAPLE_MIN_VENDORS`` vendors, minus fishing lures, gift wrap, potions, scrolls, fireworks and
  alcohol (``_NOT_FOOD``); drinks are told apart by name (``_WATER_RE``, as in shape/travel.py);
* objects named "Mailbox" for mail.

Only NPCs friendly to the faction (``friendlyToFaction``) with a usable spawn count. Role names
are Lua identifiers: plain roles (``fm``, ``inn`` ...), ``ct_<CLASS>`` for class trainers and
``pt_<Profession>`` for profession trainers.
"""

from __future__ import annotations

import re
from collections import defaultdict
from typing import Any

from pipeline.shape.coords import ZPoint, dist, valid_spawns
from pipeline.shape.data import RawData
from pipeline.shape.factions import TRAINER_SUBNAMES, FactionConfig

FLAG_ROLES: tuple[tuple[int, str], ...] = (
    (4, "vendor"),
    (8, "fm"),
    (128, "inn"),
    (256, "bank"),
    (4096, "ah"),
    (8192, "stable"),
    (16384, "repair"),
)
FLAG_TRAINER = 16

PROFESSIONS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("Alchemy", re.compile(r"alchem", re.I)),
    ("Blacksmithing", re.compile(r"blacksmith", re.I)),
    ("Cooking", re.compile(r"\bcook", re.I)),
    ("Enchanting", re.compile(r"enchant", re.I)),
    ("Engineering", re.compile(r"engineer", re.I)),
    ("FirstAid", re.compile(r"first aid", re.I)),
    ("Fishing", re.compile(r"fish", re.I)),
    ("Herbalism", re.compile(r"herbalis", re.I)),
    ("Leatherworking", re.compile(r"leatherwork", re.I)),
    ("Mining", re.compile(r"\bmin(ing|er)\b", re.I)),
    ("Skinning", re.compile(r"skinn", re.I)),
    ("Tailoring", re.compile(r"tailor", re.I)),
)

ITEM_CONTAINER, SUBCLASS_BAG = 1, 0
ITEM_CONSUMABLE = 0
STAPLE_MIN_VENDORS = 15
_NOT_FOOD = re.compile(
    r"bauble|nightcrawler|token|chronoboon|wrapping|potion|draught|scroll|firework|"
    r"mead|port|stout|pinot|bourbon|ale|grog|wine",
    re.IGNORECASE,
)
ITEM_PROJECTILE, PROJECTILE_ARROW, PROJECTILE_BULLET = 6, 2, 3
# Same heuristic as shape/travel.py: the DB has no drink flag.
_WATER_RE = re.compile(r"\b(water|milk|juice|dew|nectar|tea)\b", re.IGNORECASE)

PLAIN_ROLES: tuple[str, ...] = (
    "ah",
    "arrow",
    "bags",
    "bank",
    "bullet",
    "fm",
    "food",
    "inn",
    "mail",
    "pettrainer",
    "poison",
    "reagent",
    "repair",
    "stable",
    "vendor",
    "water",
    "weapon",
    "zeppelin",
)
CLASS_ROLES: tuple[str, ...] = tuple(sorted(f"ct_{c}" for c in set(TRAINER_SUBNAMES.values())))
PROF_ROLES: tuple[str, ...] = tuple(sorted(f"pt_{p}" for p, _ in PROFESSIONS))
ALL_ROLES: tuple[str, ...] = tuple(sorted((*PLAIN_ROLES, *CLASS_ROLES, *PROF_ROLES)))
# Roles a hub records its nearest provider for. The rest (profession trainers, poison, bags ...)
# are in the zone's ``services`` list; the runtime finds the nearest one itself. This keeps the
# hub rows small (they were the biggest part of a zone file with every role).
HUB_SERVICE_ROLES: tuple[str, ...] = tuple(
    sorted(
        (
            "ah", "arrow", "bank", "bullet", "fm", "food", "inn", "mail", "repair", "stable",
            "vendor", "water", *CLASS_ROLES,
        )
    )
)  # fmt: skip


def _sold_kinds(raw: RawData) -> dict[int, set[str]]:
    """NPC id -> {food, water, arrow, bullet, bags} from the inverse ``items.vendors`` map."""
    out: dict[int, set[str]] = defaultdict(set)
    for item in raw.items.values():
        vendors = item.get("vendors")
        if not vendors:
            continue
        cls, sub = item.get("class"), item.get("subClass")
        kind = None
        name = str(item.get("name", ""))
        if cls == ITEM_CONSUMABLE and len(vendors) >= STAPLE_MIN_VENDORS:
            if not _NOT_FOOD.search(name):
                kind = "water" if _WATER_RE.search(name) else "food"
        elif cls == ITEM_PROJECTILE and sub == PROJECTILE_ARROW:
            kind = "arrow"
        elif cls == ITEM_PROJECTILE and sub == PROJECTILE_BULLET:
            kind = "bullet"
        elif cls == ITEM_CONTAINER and sub == SUBCLASS_BAG:
            kind = "bags"
        if kind:
            for nid in vendors:
                out[int(nid)].add(kind)
    return out


def npc_roles(npc: dict[str, Any], sold: set[str]) -> list[str]:
    """Sorted role names of one NPC (empty for an NPC with no service)."""
    flags = int(npc.get("npcFlags") or 0)
    sub = str(npc.get("subName") or "")
    roles = {role for bit, role in FLAG_ROLES if flags & bit}
    if flags & FLAG_TRAINER:
        if sub in TRAINER_SUBNAMES:
            roles.add(f"ct_{TRAINER_SUBNAMES[sub]}")
        elif sub == "Pet Trainer":
            roles.add("pettrainer")
        elif sub == "Weapon Master":
            roles.add("weapon")
        else:
            for name, pattern in PROFESSIONS:
                if pattern.search(sub):
                    roles.add(f"pt_{name}")
                    break
    if "Reagent" in sub:
        roles.add("reagent")
    if "Poison" in sub:
        roles.add("poison")
    if sub == "Zeppelin Master":
        roles.add("zeppelin")
    if flags & 4:
        roles.update(sold)
    return sorted(roles)


def service_npcs(raw: RawData, cfg: FactionConfig) -> dict[int, list[str]]:
    """Faction-friendly NPCs with a usable spawn and at least one role -> their roles."""
    sold = _sold_kinds(raw)
    out: dict[int, list[str]] = {}
    for nid in sorted(raw.npcs):
        npc = raw.npcs[nid]
        if npc.get("placeholder") or cfg.own_code not in (npc.get("friendlyToFaction") or ""):
            continue
        if not valid_spawns(npc.get("spawns")):
            continue
        roles = npc_roles(npc, sold.get(nid, set()))
        if roles:
            out[nid] = roles
    return out


def mailboxes(raw: RawData) -> list[int]:
    """Object ids of mailboxes with a usable spawn."""
    return sorted(
        oid
        for oid, obj in raw.objects.items()
        if str(obj.get("name", "")).lower() == "mailbox" and valid_spawns(obj.get("spawns"))
    )


class ServiceIndex:
    """Providers per (area, role) with their spawn points, for nearest-provider lookups."""

    def __init__(self, raw: RawData, cfg: FactionConfig) -> None:
        self.roles = service_npcs(raw, cfg)
        self.mailboxes = mailboxes(raw)
        self.points: dict[tuple[str, int], list[ZPoint]] = {}
        self.by_area: dict[int, dict[str, list[tuple[str, int]]]] = defaultdict(
            lambda: defaultdict(list)
        )
        for nid, roles in self.roles.items():
            pts = valid_spawns(raw.npcs[nid].get("spawns"))
            self.points[("n", nid)] = pts
            for area in sorted({p[0] for p in pts}):
                for role in roles:
                    self.by_area[area][role].append(("n", nid))
        for oid in self.mailboxes:
            pts = valid_spawns(raw.objects[oid].get("spawns"))
            self.points[("o", oid)] = pts
            for area in sorted({p[0] for p in pts}):
                self.by_area[area]["mail"].append(("o", oid))

    def providers(self, area: int, role: str) -> list[tuple[str, int]]:
        return list(self.by_area.get(area, {}).get(role, []))

    def nearest(
        self, area: int, x: float, y: float, role: str
    ) -> tuple[tuple[str, int], float] | None:
        best: tuple[float, tuple[str, int]] | None = None
        for ref in self.providers(area, role):
            for zone, px, py in self.points[ref]:
                if zone != area:
                    continue
                d = dist((x, y), (px, py))
                if best is None or (d, ref) < best:
                    best = (d, ref)
        return None if best is None else (best[1], best[0])

    def zone_counts(self, area: int) -> dict[str, int]:
        return {
            role: len(refs) for role, refs in sorted(self.by_area.get(area, {}).items()) if refs
        }
