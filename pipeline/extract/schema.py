"""Parse the QuestieDB entity schemas from ``src/meta/*Meta.lua``.

Field indexes, names, storage types and structure shapes are read from the Lua source at run
time (via lupa). Nothing is hard-coded, so a schema change in a future QuestieDB is picked up.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

from pipeline.extract.lua_bridge import lua_to_python, new_runtime, run_lua_file

ENTITY_FILES: dict[str, str] = {
    "Quest": "questMeta.lua",
    "Npc": "npcMeta.lua",
    "Item": "itemMeta.lua",
    "Object": "objectMeta.lua",
}

# Structures whose QuestieDB reader always builds a table, even for a missing value
# (src/meta/normalize.lua, `normalize.neverNilStructures`).
NEVER_NIL_STRUCTURES = frozenset({"questgivers", "objectives"})


@dataclass(frozen=True)
class EntitySchema:
    """Schema for one entity type, as declared by QuestieDB's meta file."""

    entity: str
    meta_prefix: str
    field_count: int
    keys: dict[str, int]
    names: dict[int, str]
    types: dict[int, str]
    structures: dict[int, str]
    normalizers: dict[int, str]
    constant_values: dict[int, Any]
    empty_is_nil: frozenset[int]
    zero_pair_is_nil: frozenset[int]
    source_file: str
    source_sha256: str = field(default="")

    @property
    def prefix(self) -> str:
        """Metadata key prefix for this entity, e.g. ``X-Quest-``."""
        return "X-" + self.meta_prefix

    def index_of(self, name: str) -> int:
        """Return the field index for a field name (KeyError if the schema lacks it)."""
        return self.keys[name]


def _as_index_map(value: Any) -> dict[int, Any]:
    """Lua sequences arrive as lists and sparse tables as dicts; normalise both to int keys."""
    if isinstance(value, list):
        return {i + 1: item for i, item in enumerate(value)}
    if isinstance(value, dict):
        return {int(key): item for key, item in value.items()}
    return {}


def parse_entity_meta(meta: dict[str, Any], source_file: str) -> EntitySchema:
    """Build an :class:`EntitySchema` from the plain-Python view of one meta table."""
    return EntitySchema(
        entity=str(meta["entity"]),
        meta_prefix=str(meta["metaPrefix"]),
        field_count=int(meta["fieldCount"]),
        keys={str(name): int(index) for name, index in meta["keys"].items()},
        names=_as_index_map(meta.get("names", {})),
        types=_as_index_map(meta.get("types", {})),
        structures={k: str(v) for k, v in _as_index_map(meta.get("structures", {})).items()},
        normalizers={k: str(v) for k, v in _as_index_map(meta.get("normalize", {})).items()},
        constant_values=_as_index_map(meta.get("constantValues", {})),
        empty_is_nil=frozenset(_as_index_map(meta.get("emptyIsNil", {}))),
        zero_pair_is_nil=frozenset(_as_index_map(meta.get("zeroPairIsNil", {}))),
        source_file=source_file,
    )


def load_schemas(questiedb: Path, sha256_of: Callable[[Path], str]) -> dict[str, EntitySchema]:
    """Load the four entity schemas from ``<questiedb>/src/meta``.

    ``sha256_of`` records provenance: the digest of each meta file that was read.
    """
    meta_dir = questiedb / "src" / "meta"
    lua = new_runtime()
    schemas: dict[str, EntitySchema] = {}
    for entity, filename in ENTITY_FILES.items():
        path = meta_dir / filename
        namespace = lua.table()
        namespace.Meta = lua.table()
        run_lua_file(lua, path, namespace)
        raw_meta = lua_to_python(namespace.Meta[entity])
        if not isinstance(raw_meta, dict):
            raise ValueError(f"{filename} did not register Meta['{entity}']")
        schema = parse_entity_meta(raw_meta, source_file=f"src/meta/{filename}")
        schemas[entity] = replace(schema, source_sha256=sha256_of(path))
    return schemas
