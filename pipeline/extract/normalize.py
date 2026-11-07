"""Python port of QuestieDB's read-back rules (``src/meta/normalize.lua``).

The decoder hands every raw CBOR value to :func:`normalize_field`, which returns what a
QuestieDB read would return for that field. The rules that matter:

* a number that is missing reads back as ``0``;
* a string that is missing reads back as ``None``; ``""`` is kept;
* a table that is missing or empty reads back as ``None``, except ``questgivers`` and
  ``objectives``, which always read back as a table;
* a pair ``{0, 0}`` reads back as ``None`` where the schema says so;
* coordinates keep their values; a phase is kept only when it is non-zero;
* absent numeric slots inside objective tuples read back as ``0``.

The output keeps Lua's positional tuples as JSON lists, and reshapes ``questgivers`` and
``objectives`` into named dicts (see :mod:`pipeline.extract.decode_toc`).
"""

from __future__ import annotations

from typing import Any

from pipeline.extract.schema import NEVER_NIL_STRUCTURES, EntitySchema

# Objective slots (1-based in Lua) and the numeric slot that gets padded with 0.
_OBJECTIVE_NAMES = ("creature", "object", "item", "reputation", "killCredit", "spell")
_OBJECTIVE_PAD_SLOT = {1: 3, 2: 3, 3: 3, 5: 4, 6: 3}  # Lua slot -> 1-based tuple index


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _number_or_zero(value: Any) -> Any:
    return 0 if value is None else value


def normalize_coordinate(row: Any, keep_phase: bool) -> Any:
    """Normalize one ``{x, y, phase?}`` tuple. Malformed rows pass through unchanged."""
    if (
        not isinstance(row, list)
        or len(row) < 2
        or not _is_number(row[0])
        or not _is_number(row[1])
    ):
        return row
    if row[0] == -1 and row[1] == -1:
        return [-1, -1]
    if keep_phase and len(row) > 2 and _number_or_zero(row[2]) != 0:
        return [row[0], row[1], row[2]]
    return [row[0], row[1]]


def zone_entries(value: Any) -> list[tuple[str, Any]]:
    """``(zoneId, entry)`` pairs from a zone-keyed value.

    CBOR stores a Lua table as a map when its keys are sparse and as an array when they are
    1..n. An array element at position ``i`` is therefore zone ``i + 1`` (Lua indexes from 1),
    and ``None`` holes are skipped.
    """
    if isinstance(value, dict):
        return [(str(zone_id), entry) for zone_id, entry in value.items()]
    if isinstance(value, list):
        return [(str(i + 1), entry) for i, entry in enumerate(value) if entry is not None]
    return []


def is_zone_keyed(value: Any) -> bool:
    """True for a spawnlist/waypointlist shape (map or array), False for anything else."""
    return isinstance(value, (dict, list))


def normalize_spawnlist(value: Any) -> Any:
    """``zoneId -> [{x, y, phase?}, ...]``. Zone IDs become strings so the JSON stays valid."""
    if not is_zone_keyed(value):
        return value
    out: dict[str, Any] = {}
    for zone_id, rows in zone_entries(value):
        if isinstance(rows, list):
            out[zone_id] = [normalize_coordinate(row, keep_phase=True) for row in rows]
        else:
            out[zone_id] = rows
    return out


def normalize_waypointlist(value: Any) -> Any:
    """``zoneId -> [[{x, y}, ...], ...]``: paths of waypoints, never with a phase."""
    if not is_zone_keyed(value):
        return value
    out: dict[str, Any] = {}
    for zone_id, paths in zone_entries(value):
        if isinstance(paths, list):
            out[zone_id] = [
                [normalize_coordinate(row, keep_phase=False) for row in path]
                if isinstance(path, list)
                else path
                for path in paths
            ]
        else:
            out[zone_id] = paths
    return out


def _pad_tuples(entries: Any, slot: int) -> Any:
    """Give each tuple a 0 in ``slot`` (1-based) when that slot is absent."""
    if not isinstance(entries, list):
        return entries
    padded: list[Any] = []
    for entry in entries:
        if isinstance(entry, list):
            entry = list(entry)
            if len(entry) == slot - 1:
                entry.append(0)
        padded.append(entry)
    return padded


def normalize_objectives(value: Any) -> dict[str, Any]:
    """``[creature, object, item, reputation, killCredit, spell]`` -> named, padded dict."""
    out: dict[str, Any] = {}
    slots = value if isinstance(value, list) else []
    for index, name in enumerate(_OBJECTIVE_NAMES, start=1):
        if index > len(slots) or slots[index - 1] is None:
            continue
        entry = slots[index - 1]
        if index in _OBJECTIVE_PAD_SLOT:
            entry = _pad_tuples(entry, _OBJECTIVE_PAD_SLOT[index])
        out[name] = entry
    return out


def normalize_extraobjectives(value: Any) -> Any:
    """Rows of ``[spawnlist, icon, text, objectiveIndex, reflist]``; slot 4 defaults to 0."""
    if not isinstance(value, list):
        return value
    rows: list[Any] = []
    for row in value:
        if isinstance(row, list):
            row = list(row)
            if row and is_zone_keyed(row[0]):
                row[0] = normalize_spawnlist(row[0])
            if len(row) == 3:
                row.append(0)
        rows.append(row)
    return rows


def normalize_questgivers(value: Any) -> dict[str, list[Any]]:
    """``[npcs?, objects?, items?]`` -> ``{npcs, objects, items}`` (missing lists are empty)."""
    parts = value if isinstance(value, list) else []
    return {
        "npcs": list(parts[0]) if len(parts) > 0 and parts[0] is not None else [],
        "objects": list(parts[1]) if len(parts) > 1 and parts[1] is not None else [],
        "items": list(parts[2]) if len(parts) > 2 and parts[2] is not None else [],
    }


def normalize_trigger(value: Any) -> Any:
    """``[text, spawnlist]``; the spawnlist is normalized in place."""
    if not isinstance(value, list) or len(value) < 2 or not is_zone_keyed(value[1]):
        return value
    return [value[0], normalize_spawnlist(value[1]), *value[2:]]


def normalize_faction(value: Any) -> Any:
    """``friendlyToFaction``: ``None``/``""`` -> ``None``; ``"A"``/``"H"`` kept; else ``"AH"``."""
    if value is None or value == "":
        return None
    if value in ("A", "H"):
        return value
    return "AH"


_STRUCTURE_NORMALIZERS = {
    "spawnlist": normalize_spawnlist,
    "waypointlist": normalize_waypointlist,
    "trigger": normalize_trigger,
    "extraobjectives": normalize_extraobjectives,
    "objectives": normalize_objectives,
    "questgivers": normalize_questgivers,
}

_NAMED_NORMALIZERS = {"faction": normalize_faction}


def normalize_field(schema: EntitySchema, index: int, raw: Any) -> Any:
    """Return the QuestieDB read-back value for one field, or ``None`` when it is absent."""
    if index in schema.constant_values:
        return schema.constant_values[index]

    storage = schema.types.get(index)
    if storage == "number":
        return _number_or_zero(raw)

    if storage == "string":
        named = schema.normalizers.get(index)
        if named is not None:
            return _NAMED_NORMALIZERS[named](raw)
        return raw

    structure = schema.structures.get(index)
    never_nil = structure in NEVER_NIL_STRUCTURES

    if raw is None or (isinstance(raw, (list, dict)) and len(raw) == 0):
        return _empty_table(structure) if never_nil else None
    if not isinstance(raw, (list, dict)):
        return raw

    if index in schema.zero_pair_is_nil and isinstance(raw, list):
        first = _number_or_zero(raw[0] if len(raw) > 0 else None)
        second = _number_or_zero(raw[1] if len(raw) > 1 else None)
        if first == 0 and second == 0:
            return None

    if structure in _STRUCTURE_NORMALIZERS:
        return _STRUCTURE_NORMALIZERS[structure](raw)
    return raw


def _empty_table(structure: str | None) -> Any:
    if structure == "questgivers":
        return {"npcs": [], "objects": [], "items": []}
    return {}
