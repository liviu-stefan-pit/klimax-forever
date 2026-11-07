"""Support data: quest XP table, zone maps and the zone name enum.

* ``xp.json``: ``{questId: [level, xp]}`` from ``support/Forever/QuestXP/xpDB-classic.lua``.
* ``zones.json``: zone maps and the zone name enum. The zone map files only hold *overrides*
  (Lua source inside long strings, plus a few direct assignments). They are evaluated with
  a stub ``QuestieLoader`` so the output is what QuestieDB itself would load.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from pipeline.extract.lua_bridge import lua_to_python, new_runtime, run_lua_file

XP_LINE = re.compile(r"^\s*\[(\d+)\]\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*\}")

ZONE_FILES = (
    "areaIdToUiMapId.lua",
    "uiMapIdToAreaId.lua",
    "subZoneToParentZone.lua",
    "instanceIdToAreaId.lua",
    "dungeons.lua",
)

_EVAL = (
    "function(src, name) local fn, err = load(src, name); "
    "if not fn then error(err, 0) end; return fn() end"
)

# Lua stub: just enough for the zone files to load without the add-on around them.
_STUB = """
local ZoneDB = { private = {}, zoneIDs = {} }
-- Forever is gated as Era (order 1): later-expansion branches stay off.
local Expansions = { Classic = 1, Tbc = 2, Wotlk = 3, Cata = 4, MoP = 5, Current = 1 }
local modules = { ZoneDB = ZoneDB, Expansions = Expansions }
QuestieLoader = {
  ImportModule = function(self, name)
    local m = modules[name]
    if m == nil then m = {}; modules[name] = m end
    return m
  end,
}
function UnitFactionGroup() return "Alliance" end
return ZoneDB, Expansions
"""


@dataclass
class SupportReport:
    """Counts and skips from the support step."""

    xp_entries: int = 0
    zone_sections: dict[str, int] = field(default_factory=dict)
    skipped: list[dict[str, str]] = field(default_factory=list)


def parse_xp(path: Path) -> dict[str, list[int]]:
    """Parse ``[questId] = {level, xp}`` rows. Keys are strings so JSON stays valid."""
    out: dict[str, list[int]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = XP_LINE.match(line)
        if match:
            out[match.group(1)] = [int(match.group(2)), int(match.group(3))]
    return out


def load_zone_enum(questiedb: Path) -> dict[str, Any]:
    """Read ``zoneIDs`` (the zone name enum) from ``src/corrections/enum/zones.lua``."""
    lua = new_runtime()
    namespace = lua.table()
    namespace.Enum = lua.table()
    run_lua_file(lua, questiedb / "src" / "corrections" / "enum" / "zones.lua", namespace)
    enum = lua_to_python(namespace.Enum)
    zone_ids = enum.get("zoneIDs") if isinstance(enum, dict) else None
    if not isinstance(zone_ids, dict):
        raise ValueError("zones.lua did not define Enum.zoneIDs")
    return {str(name): value for name, value in zone_ids.items()}


def load_zone_maps(questiedb: Path, report: SupportReport) -> dict[str, Any]:
    """Run the Forever zone support files under the stub and collect their data."""
    support_dir = questiedb / "support" / "Forever" / "Zones"
    zone_enum = load_zone_enum(questiedb)
    lua = new_runtime()
    zone_db, _expansions = lua.execute(_STUB)
    zone_db.zoneIDs = _as_lua_table(lua, zone_enum)
    evaluate = lua.eval(_EVAL)

    for filename in ZONE_FILES:
        path = support_dir / filename
        if not path.is_file():
            report.skipped.append({"file": f"support/Forever/Zones/{filename}", "error": "missing"})
            continue
        try:
            run_lua_file(lua, path, lua.table())
        except Exception as exc:  # lupa raises LuaError; keep the reason and keep going
            report.skipped.append({"file": f"support/Forever/Zones/{filename}", "error": str(exc)})

    out: dict[str, Any] = {}
    for lua_name, py_name in (
        ("areaIdToUiMapIdOverride", "areaIdToUiMapId"),
        ("uiMapIdToAreaIdOverride", "uiMapIdToAreaId"),
        ("subZoneToParentZoneOverride", "subZoneToParentZone"),
    ):
        source = zone_db.private[lua_name]
        if source is None:
            report.skipped.append({"file": lua_name, "error": "override not defined by any file"})
            continue
        try:
            out[py_name] = lua_to_python(evaluate(source, lua_name))
        except Exception as exc:
            report.skipped.append({"file": lua_name, "error": str(exc)})

    instance_map = lua_to_python(zone_db["instanceIdToAreaId"])
    if instance_map is not None:
        out["instanceIdToAreaId"] = instance_map
    dungeons = lua_to_python(zone_db.private["dungeons"])
    if dungeons is not None:
        out["dungeons"] = dungeons
    else:
        report.skipped.append({"file": "dungeons", "error": "ZoneDB.private.dungeons not set"})

    out["zoneIDs"] = zone_enum
    for key in sorted(out):
        report.zone_sections[key] = len(out[key])
    return dict(sorted(out.items()))


def _as_lua_table(lua: Any, data: dict[str, Any]) -> Any:
    """Build a Lua table from a Python dict (used to hand the zone enum to the stub)."""
    table = lua.table()
    for key, value in data.items():
        table[key] = value
    return table
