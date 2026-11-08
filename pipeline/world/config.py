"""Settings for the world compile. Everything tunable lives here, with the reason next to it."""

from __future__ import annotations

from dataclasses import dataclass, field

# Zones compiled by default (phase 19 "done when": the four start zones). The three capitals are
# included because the start zones hand quests in there and they hold the services a start zone
# lacks (auction house, bank, most trainers). Later phases add zones (phase 25 and 26).
DEFAULT_ZONES: tuple[str, ...] = (
    "DUROTAR",
    "MULGORE",
    "TIRISFAL_GLADES",
    "ZEPHRAS_ISLE",
    "ORGRIMMAR",
    "THUNDER_BLUFF",
    "UNDERCITY",
    # Phase 25: levels 1 to 20 beyond the start zones.
    "SILVERPINE_FOREST",
    "THE_BARRENS",
    "STONETALON_MOUNTAINS",
    "ASHENVALE",
    # Phase 26: levels 20 to 40.
    "THOUSAND_NEEDLES",
    "HILLSBRAD_FOOTHILLS",
    "ARATHI_HIGHLANDS",
    "DESOLACE",
    "DUSTWALLOW_MARSH",
    "STRANGLETHORN_VALE",
    "SWAMP_OF_SORROWS",
    "BADLANDS",
    "TANARIS",
    "THE_HINTERLANDS",
    # Phase 31: levels 40 to 60. QuestieDB has no Shen'dralas zone (only the Shen'dralar
    # faction), and Riverglades, The Drowned City and Krol'dok have almost no quests yet.
    "FERALAS",
    "AZSHARA",
    "FELWOOD",
    "UN_GORO_CRATER",
    "WINTERSPRING",
    "WESTERN_PLAGUELANDS",
    "EASTERN_PLAGUELANDS",
    "BURNING_STEPPES",
    "SEARING_GORGE",
    "BLASTED_LANDS",
    "SILITHUS",
)

# Plan scope is levels 1 to 60 (DYNAMIC_GUIDE_PLAN s2; phase 31 raised it from 40). A quest is
# compiled when a character of this level or lower can accept it (requiredLevel).
MAX_REQUIRED_LEVEL = 60

# Hub clustering (map-%): quest givers and turn-ins closer than this chain into one hub. Every
# giver belongs to a hub (min samples 1), so a lone camp is a one-NPC hub, never lost as noise.
HUB_EPS = 3.0
# A required service within this distance (map-%, same zone) counts as "nearby" for a hub.
SERVICE_NEARBY = 12.0
# Services every hub should have nearby (DYNAMIC_GUIDE_PLAN s7); otherwise the hub lists a gap.
REQUIRED_HUB_ROLES: tuple[str, ...] = ("fm", "inn", "vendor")

# Positions kept per NPC/object (spawn cluster centres) and per objective.
MAX_NPC_POINTS = 3
MAX_OBJECTIVE_POINTS = 3

# Per-file size budget for the generated Lua (bytes). The largest compiled band route is 60 KB;
# a zone file holds the zone's whole quest graph, so it gets a little more. A warning first.
SIZE_BUDGET = 160 * 1024
# Phase 31 raised the warning from 128 KB: with 32 zones `Index.lua` (where every quest, NPC and
# object lives) is about 141 KB. Zone files stay far below it; the hard budget is unchanged.
SIZE_WARN = 148 * 1024

# Rough travel costs in seconds for the planner (phase 21 tunes them). Not measured in game.
TRAVEL_COSTS: dict[str, int] = {
    "boat": 300,  # about 2 minutes of waiting plus the crossing
    "hearth": 30,  # 10 s cast plus a loading screen; 1 hour cooldown, needs a bind
    "zeppelin": 300,  # same as a boat
    "zoneBorder": 60,  # extra cost of crossing into a neighbouring zone on foot
}


@dataclass(frozen=True)
class WorldConfig:
    faction: str = "horde"
    zones: tuple[str, ...] = DEFAULT_ZONES
    max_required_level: int = MAX_REQUIRED_LEVEL
    hub_eps: float = HUB_EPS
    service_nearby: float = SERVICE_NEARBY
    required_hub_roles: tuple[str, ...] = REQUIRED_HUB_ROLES
    size_budget: int = SIZE_BUDGET
    size_warn: int = SIZE_WARN
    travel_costs: dict[str, int] = field(default_factory=lambda: dict(TRAVEL_COSTS))
