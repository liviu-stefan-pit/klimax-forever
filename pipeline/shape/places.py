"""Hand-typed settlement names, used only to label hubs and travel-graph entries.

QuestieDB has no sub-zone or town names, so a hub is named by the closest entry here.
Positions of services (innkeeper, flight master) come from the data; the *names* and the
quest-hub-only positions (Valley of Trials, Camp Narache, Deathknell, Sen'jin Village) are
typed from game knowledge and are approximate. A name is only applied when the hub is within
``NAME_RADIUS`` map-% of an entry in the same zone. Everything else falls back to the zone name.

Entries: (zone enum name, x, y, settlement name).
"""

from __future__ import annotations

NAME_RADIUS = 8.0

MANUAL_NOTE = (
    "Settlement names typed by hand (phase 02). Coordinates of towns with an innkeeper or flight "
    "master come from the DB; Valley of Trials, Camp Narache, Deathknell and Sen'jin Village are "
    "approximate. Used only for labels, never for validation."
)

SETTLEMENTS: dict[str, tuple[tuple[str, float, float, str], ...]] = {
    "horde": (
        ("DUROTAR", 43.5, 68.5, "Valley of Trials"),
        ("DUROTAR", 51.5, 41.6, "Razor Hill"),
        ("DUROTAR", 56.0, 73.5, "Sen'jin Village"),
        ("MULGORE", 44.5, 77.0, "Camp Narache"),
        ("MULGORE", 46.0, 61.0, "Bloodhoof Village"),
        ("TIRISFAL_GLADES", 32.0, 65.0, "Deathknell"),
        ("TIRISFAL_GLADES", 61.0, 52.0, "Brill"),
        ("SILVERPINE_FOREST", 43.2, 41.3, "The Sepulcher"),
        ("THE_BARRENS", 52.0, 30.0, "The Crossroads"),
        ("THE_BARRENS", 62.5, 38.5, "Ratchet"),
        ("THE_BARRENS", 45.0, 59.0, "Camp Taurajo"),
        ("STONETALON_MOUNTAINS", 46.0, 61.0, "Sun Rock Retreat"),
        ("ASHENVALE", 74.0, 61.0, "Splintertree Post"),
        ("ASHENVALE", 12.2, 33.8, "Zoram'gar Outpost"),
        ("HILLSBRAD_FOOTHILLS", 62.0, 19.0, "Tarren Mill"),
        ("THOUSAND_NEEDLES", 45.5, 50.0, "Freewind Post"),
        ("DESOLACE", 23.0, 71.0, "Shadowprey Village"),
        ("FERALAS", 75.0, 45.0, "Camp Mojache"),
        ("TANARIS", 52.0, 26.5, "Gadgetzan"),
        ("DUSTWALLOW_MARSH", 35.5, 31.9, "Brackenwall Village"),
        ("ARATHI_HIGHLANDS", 73.5, 32.5, "Hammerfall"),
        ("THE_HINTERLANDS", 80.0, 81.5, "Revantusk Village"),
        ("BADLANDS", 3.5, 45.5, "Kargath"),
        ("SEARING_GORGE", 34.8, 30.9, "Thorium Point"),
        ("STRANGLETHORN_VALE", 31.5, 29.5, "Grom'gol Base Camp"),
        ("STRANGLETHORN_VALE", 27.0, 77.2, "Booty Bay"),
        ("SWAMP_OF_SORROWS", 45.5, 55.5, "Stonard"),
        ("AZSHARA", 22.0, 49.6, "Valormok"),
        ("FELWOOD", 34.4, 54.0, "Bloodvenom Post"),
        ("WINTERSPRING", 61.0, 37.5, "Everlook"),
        ("BURNING_STEPPES", 65.7, 24.2, "Flame Crest"),
        ("EASTERN_PLAGUELANDS", 71.0, 48.0, "Light's Hope Chapel"),
        ("SILITHUS", 50.5, 38.0, "Cenarion Hold"),
        ("UN_GORO_CRATER", 45.2, 5.8, "Marshal's Refuge"),
    ),
}


def settlement_name(
    faction: str, zone_name_to_id: dict[str, int], zone: int, x: float, y: float
) -> str | None:
    """Nearest settlement name in ``zone`` within ``NAME_RADIUS``, else ``None``."""
    best: tuple[float, str] | None = None
    for z_enum, sx, sy, name in SETTLEMENTS.get(faction, ()):
        if zone_name_to_id.get(z_enum) != zone:
            continue
        d = ((sx - x) ** 2 + (sy - y) ** 2) ** 0.5
        if d <= NAME_RADIUS and (best is None or d < best[0]):
            best = (d, name)
    return best[1] if best else None
