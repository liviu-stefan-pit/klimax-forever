"""Transport and map facts read from the installed game's add-ons (``data/raw/game/``).

Sources (all read in place, never written to; see docs/GAME_DATA.md for licences):

* ``Leatrix_Maps/Leatrix_Maps_Icons.lua``: boat, zeppelin and portal docks and flight points,
  keyed by uiMapID, with map-% coordinates. Used for facts only (coordinates, names).
* ``GatherLite/scripts/maps/zone-neighbors.lua``: uiMapID parent and neighbour tables.
* ``RXPGuides/DB/forever/flightData.lua``: flight node names and links. **Cross-check only**;
  the output goes to ``crosscheck`` in ``transport.json`` and is never merged into repo data.

The Lua files are real tables, so they run under lupa with tiny stubs (no regex on the data).
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

from pipeline.extract.lua_bridge import new_runtime

DEFAULT_ADDONS = Path(r"C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns")
DEFAULT_OUT = Path("data/raw/game")

LEATRIX = Path("Leatrix_Maps") / "Leatrix_Maps_Icons.lua"
ZONE_TREE = Path("GatherLite") / "scripts" / "maps" / "zone-neighbors.lua"
RXP_FLIGHTS = Path("RXPGuides") / "DB" / "forever" / "flightData.lua"

_LOADFILE = "function(p) local f, e = loadfile(p); if not f then error(e, 0) end; return f end"
_LOCALE_STUB = "setmetatable({}, {__index = function(_, k) return k end})"
_FACTIONS = {"A": "Alliance", "H": "Horde", "N": "Neutral"}
_KINDS = ("Travel", "Portal", "Flight")
_TRAVEL_RE = re.compile(r"^(?P<mode>Boat|Zeppelin|Portal) to (?P<dest>.+)$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _toc_field(addon_dir: Path, key: str) -> str | None:
    for toc in sorted(addon_dir.glob("*.toc")):
        for line in toc.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith(f"## {key}:"):
                return line.split(":", 1)[1].strip()
    return None


def source_record(addons: Path, rel: Path) -> dict[str, Any]:
    """Manifest row for one source file: path, add-on version and sha256."""
    return {
        "file": rel.as_posix(),
        "addon": rel.parts[0],
        "addonVersion": _toc_field(addons / rel.parts[0], "Version"),
        "sha256": sha256_file(addons / rel),
    }


def _chunk(lua: Any, path: Path) -> Any:
    return lua.eval(_LOADFILE)(str(path))


def read_leatrix(path: Path) -> list[dict[str, Any]]:
    """Icon rows from ``Leatrix_Maps["Icons"]`` as plain dicts (map id order, then file order)."""
    lua = new_runtime()
    lua.execute("function GetBuildInfo() return '1.60.1', '0', '', 16001 end")
    leatrix = lua.table()
    leatrix.L = lua.eval(_LOCALE_STUB)
    _chunk(lua, path)(None, leatrix)
    rows: list[dict[str, Any]] = []
    for ui_map in sorted(leatrix["Icons"].keys()):
        entries = leatrix["Icons"][ui_map]
        for i in range(1, len(entries) + 1):
            entry = entries[i]
            kind = entry[1]
            group = next((k for k in _KINDS if isinstance(kind, str) and kind.startswith(k)), None)
            if group is None:
                continue
            suffix = kind[len(group):]
            dest = entry[13]
            rows.append(
                {
                    "group": group.lower(),
                    "type": kind,
                    "faction": _FACTIONS.get(suffix, suffix or None),
                    "uiMapId": int(ui_map),
                    "x": float(entry[2]),
                    "y": float(entry[3]),
                    "label": entry[4],
                    "sublabel": entry[5],
                    "destUiMapId": int(dest) if dest is not None else None,
                }
            )
    return rows


def split_travel_label(label: str) -> dict[str, str | None]:
    """``"Boat to Booty Bay, Stranglethorn"`` -> mode ``boat``, place ``Booty Bay``."""
    match = _TRAVEL_RE.match(label)
    if not match:
        return {"mode": None, "place": None, "region": None}
    first, _, rest = match.group("dest").partition(", ")
    return {"mode": match.group("mode").lower(), "place": first, "region": rest or None}


def read_zone_tree(path: Path) -> dict[int, dict[str, Any]]:
    """GatherLite ``addon.zoneTree``: uiMapID -> name, parent, mapType, neighbours."""
    lua = new_runtime()
    addon = lua.table()
    _chunk(lua, path)("GatherLite", addon)
    tree = addon["zoneTree"]
    out: dict[int, dict[str, Any]] = {}
    for ui_map in sorted(tree.keys()):
        node = tree[ui_map]
        neighbours = node["neighbors"]
        out[int(ui_map)] = {
            "name": node["name"],
            "parent": int(node["parent"]),
            "mapType": int(node["mapType"]),
            "neighbors": sorted(int(neighbours[i]) for i in range(1, len(neighbours) + 1)),
        }
    return out


def read_rxp_flights(path: Path) -> dict[str, dict[int, dict[str, Any]]]:
    """RXPGuides ``addon.FPDB``: faction -> node id -> {name, links}. Cross-check only."""
    lua = new_runtime()
    addon = lua.table()
    addon.game = "FOREVER"
    _chunk(lua, path)("RXPGuides", addon)
    out: dict[str, dict[int, dict[str, Any]]] = {}
    for faction in sorted(addon["FPDB"].keys()):
        table = addon["FPDB"][faction]
        nodes: dict[int, dict[str, Any]] = {}
        for node_id in sorted(k for k in table.keys() if isinstance(k, (int, float))):
            node = table[node_id]
            links = sorted(int(k) for k in node.keys() if isinstance(k, (int, float)))
            nodes[int(node_id)] = {"name": node["name"], "links": links}
        out[str(faction)] = nodes
    return out


def build_transport(addons: Path = DEFAULT_ADDONS) -> dict[str, Any]:
    """Everything the shape merge and the cross-check need, as plain sorted data."""
    icons = read_leatrix(addons / LEATRIX)
    links = [
        {**row, **split_travel_label(row["label"])} for row in icons if row["group"] != "flight"
    ]
    flights = [row for row in icons if row["group"] == "flight"]
    tree = read_zone_tree(addons / ZONE_TREE)
    rxp = read_rxp_flights(addons / RXP_FLIGHTS)
    return {
        "sources": [source_record(addons, rel) for rel in (LEATRIX, ZONE_TREE, RXP_FLIGHTS)],
        "links": links,
        "flightPoints": flights,
        "zoneTree": {str(k): v for k, v in tree.items()},
        "crosscheck": {
            "note": "RXPGuides flight nodes. Cross-check only: never merged into repo data.",
            "rxpFlightNodes": {
                faction: {str(i): n for i, n in nodes.items()} for faction, nodes in rxp.items()
            },
        },
    }


def write_transport(addons: Path = DEFAULT_ADDONS, out_dir: Path = DEFAULT_OUT) -> Path:
    data = build_transport(addons)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "transport.json"
    text = json.dumps(data, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")
    return path
