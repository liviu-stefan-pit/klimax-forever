"""Zone (area id) -> ``uiMapID`` for the compiler.

``data/raw/zones.json`` only holds QuestieDB's *override* table (``areaIdToUiMapId``): the base
Classic zones (Durotar, Mulgore, the Barrens, ...) are not in the vendored copy. The ids below
fill that gap. They are the Classic ``UiMap`` ids as listed on wow.tools / Wowpedia, typed by
hand in phase 03 and **not yet checked in game** (see docs/PROGRESS.md, open questions). An
override from ``zones.json`` always wins over this table.

Zephra's Isle (16593) and Riverglades (16591) are Forever-only zones with no known uiMapID; a
route that uses them fails to compile until the id is added here or to the DB overrides.
"""

from __future__ import annotations

# area id -> uiMapID (hand-typed, see module docstring)
BASE_UI_MAPS: dict[int, int] = {
    3: 1418,  # Badlands
    4: 1419,  # Blasted Lands
    8: 1435,  # Swamp of Sorrows
    14: 1411,  # Durotar
    15: 1445,  # Dustwallow Marsh
    16: 1447,  # Azshara
    17: 1413,  # The Barrens
    28: 1422,  # Western Plaguelands
    33: 1434,  # Stranglethorn Vale
    36: 1416,  # Alterac Mountains
    45: 1417,  # Arathi Highlands
    46: 1428,  # Burning Steppes
    47: 1425,  # The Hinterlands
    51: 1427,  # Searing Gorge
    85: 1420,  # Tirisfal Glades
    130: 1421,  # Silverpine Forest
    139: 1423,  # Eastern Plaguelands
    215: 1412,  # Mulgore
    267: 1424,  # Hillsbrad Foothills
    331: 1440,  # Ashenvale
    357: 1444,  # Feralas
    361: 1448,  # Felwood
    400: 1441,  # Thousand Needles
    405: 1443,  # Desolace
    406: 1442,  # Stonetalon Mountains
    440: 1446,  # Tanaris
    490: 1449,  # Un'Goro Crater
    493: 1450,  # Moonglade
    618: 1452,  # Winterspring
    1377: 1451,  # Silithus
    1497: 1458,  # Undercity
    1637: 1454,  # Orgrimmar
    1638: 1456,  # Thunder Bluff
    2597: 1459,  # Alterac Valley
}


def ui_map_for(area_id: int, overrides: dict[int, int]) -> int | None:
    """uiMapID for a zone, or None if unknown. A non-zero override from zones.json wins."""
    override = overrides.get(area_id)
    if override:
        return override
    return BASE_UI_MAPS.get(area_id)
