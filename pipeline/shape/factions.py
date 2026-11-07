"""Faction configuration for the shape step.

Everything that differs between factions lives here, so Alliance later is a new
``FactionConfig`` entry plus ``--faction alliance``. Zones are referred to by their
``zones.json -> zoneIDs`` enum name (for example ``DUROTAR``), never by number.
"""

from __future__ import annotations

from dataclasses import dataclass, field

# requiredClasses bit for each class token (1 << (classId - 1), the WoW ChrClasses order).
CLASS_BITS: dict[str, int] = {
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

# NPC subName -> class token, for class trainers (travel.json).
TRAINER_SUBNAMES: dict[str, str] = {
    "Warrior Trainer": "WARRIOR",
    "Paladin Trainer": "PALADIN",
    "Hunter Trainer": "HUNTER",
    "Rogue Trainer": "ROGUE",
    "Priest Trainer": "PRIEST",
    "Shaman Trainer": "SHAMAN",
    "Mage Trainer": "MAGE",
    "Warlock Trainer": "WARLOCK",
    "Druid Trainer": "DRUID",
}


@dataclass(frozen=True)
class Branch:
    """A race-specific start route (PRD §2 "Start branch")."""

    id: str
    races: tuple[str, ...]
    start_hub: str
    # Zones that belong to this branch outright.
    home_zones: tuple[str, ...]
    # Neighbouring zones the branch spills into from `reach_from_level` upward.
    reach_zones: tuple[str, ...] = ()
    reach_from_level: int = 5


@dataclass(frozen=True)
class FactionConfig:
    id: str
    # Race name -> requiredRaces bit. Derived masks are computed from this, never hard-coded.
    race_bits: dict[str, int]
    # Forever sets bit 32 / bit 33 of requiredRaces as an "Alliance" / "Horde" faction flag
    # on top of the per-race bits (found in phase 02, see docs/PROGRESS.md).
    faction_flag: int
    other_faction_flag: int
    # friendlyToFaction codes: a quest whose NPC starters are all friendly only to the
    # opposing faction is dropped.
    own_code: str
    opposing_code: str
    branches: tuple[Branch, ...]
    shared_track: str
    # Bands (lo, hi) that are always split per branch.
    split_bands: tuple[tuple[int, int], ...]
    # Bands that are split only if the data shows two separable populations.
    detect_split_bands: tuple[tuple[int, int], ...]
    # Branch whose region is separated off in a detected split (rest stays the shared track).
    late_split_branch: str
    late_split_zones: tuple[str, ...]
    late_split_min_quests: int
    # Rough north-to-south / west-to-east zone order, used to cut oversized packs by sub-region.
    zone_order: tuple[str, ...]
    # Subnames (flight masters etc.) used to generate the travel graph candidates.
    flight_master_subnames: tuple[str, ...]
    levels: tuple[int, int] = (1, 60)
    band_width: int = 5
    overlap: int = 2
    extra: dict[str, object] = field(default_factory=dict)

    @property
    def race_mask(self) -> int:
        mask = 0
        for bit in self.race_bits.values():
            mask |= bit
        return mask

    def branch(self, branch_id: str) -> Branch:
        for branch in self.branches:
            if branch.id == branch_id:
                return branch
        raise KeyError(branch_id)

    def branch_race_mask(self, branch_id: str) -> int:
        mask = 0
        for race in self.branch(branch_id).races:
            mask |= self.race_bits[race]
        return mask


HORDE = FactionConfig(
    id="horde",
    race_bits={"Orc": 2, "Undead": 16, "Tauren": 32, "Troll": 128},
    faction_flag=1 << 33,
    other_faction_flag=1 << 32,
    own_code="H",
    opposing_code="A",
    branches=(
        Branch(
            id="durotar",
            races=("Orc", "Troll"),
            start_hub="Razor Hill",
            home_zones=("DUROTAR", "ORGRIMMAR"),
            reach_zones=("THE_BARRENS",),
        ),
        Branch(
            id="mulgore",
            races=("Tauren",),
            start_hub="Bloodhoof Village",
            home_zones=("MULGORE", "THUNDER_BLUFF"),
            reach_zones=("THE_BARRENS",),
        ),
        Branch(
            id="tirisfal",
            races=("Undead",),
            start_hub="Brill",
            home_zones=("TIRISFAL_GLADES", "UNDERCITY"),
            reach_zones=("SILVERPINE_FOREST",),
        ),
        # Forever-only start zone. Open to every Horde race; how characters reach it is not in
        # the data, so the reach zones are an assumption. Added at the user's request.
        Branch(
            id="zephras",
            races=("Orc", "Troll", "Tauren", "Undead"),
            start_hub="Zephra's Isle",
            home_zones=("ZEPHRAS_ISLE",),
            # Assumed hand-off (user: "Orgrimmar or the Barrens"), unconfirmed.
            reach_zones=("ORGRIMMAR", "THE_BARRENS"),
        ),
    ),
    shared_track="horde",
    split_bands=((1, 5), (5, 10)),
    detect_split_bands=((10, 15),),
    late_split_branch="tirisfal",
    late_split_zones=("TIRISFAL_GLADES", "SILVERPINE_FOREST", "UNDERCITY"),
    late_split_min_quests=15,
    zone_order=(
        # Eastern Kingdoms, north to south
        "TIRISFAL_GLADES",
        "UNDERCITY",
        "SILVERPINE_FOREST",
        "WESTERN_PLAGUELANDS",
        "EASTERN_PLAGUELANDS",
        "HILLSBRAD_FOOTHILLS",
        "ALTERAC_MOUNTAINS",
        "ARATHI_HIGHLANDS",
        "THE_HINTERLANDS",
        "SEARING_GORGE",
        "BURNING_STEPPES",
        "BADLANDS",
        "SWAMP_OF_SORROWS",
        "BLASTED_LANDS",
        "STRANGLETHORN_VALE",
        # Kalimdor, north to south
        "WINTERSPRING",
        "FELWOOD",
        "AZSHARA",
        "ASHENVALE",
        "DUROTAR",
        "ORGRIMMAR",
        "STONETALON_MOUNTAINS",
        "THE_BARRENS",
        "MULGORE",
        "THUNDER_BLUFF",
        "DESOLACE",
        "DUSTWALLOW_MARSH",
        "THOUSAND_NEEDLES",
        "FERALAS",
        "UN_GORO_CRATER",
        "TANARIS",
        "SILITHUS",
    ),  # fmt: skip
    flight_master_subnames=(
        "Flight Master",
        "Wind Rider Master",
        "Bat Handler",
        "Thunder Bluff Flight Master",
    ),
)

FACTIONS: dict[str, FactionConfig] = {HORDE.id: HORDE}


def get_faction(faction_id: str) -> FactionConfig:
    try:
        return FACTIONS[faction_id]
    except KeyError:
        known = ", ".join(sorted(FACTIONS))
        raise SystemExit(f"unknown faction '{faction_id}' (known: {known})") from None
