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
)

# Plan scope is levels 1 to 40 (DYNAMIC_GUIDE_PLAN s2). A quest is compiled when a character of
# this level or lower can accept it (requiredLevel), so the yellow quests of a level 40 are in.
MAX_REQUIRED_LEVEL = 40

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
SIZE_WARN = 128 * 1024

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
