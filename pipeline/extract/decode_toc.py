"""Stream ``QuestieDB_Forever.toc`` and decode the baked entity store.

The TOC carries the whole database as ``## X-<Entity>...: <value>`` metadata lines:

* ``X-<Entity>-IDS``: base64 -> decompress -> CBOR array of IDs (may be chunked);
* ``X-<Entity>-<id>-S``: base64 -> CBOR map ``{fieldIndex: scalar, "p": presenceBitmask}``;
* ``X-<Entity>-<id>-<fieldIndex>``: base64 -> CBOR, present only when bit ``fieldIndex-1``
  of ``p`` is set (table fields).

A value of exactly ``~N~`` means the value is split over ``<key>-1 .. <key>-N``.
"""

from __future__ import annotations

import base64
import gzip
import re
import zlib
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import cbor2

from pipeline.extract.normalize import normalize_field
from pipeline.extract.schema import EntitySchema

CHUNK_HEADER = re.compile(r"^~(\d+)~$")
ENTITY_KEY_PREFIXES = ("X-Quest-", "X-Npc-", "X-Item-", "X-Object-")
HEADER_KEYS = frozenset(
    {
        "Version",
        "Interface",
        "X-Contract-Version",
        "X-Flavor",
        "X-Mode",
        "X-BUILD-COMMIT",
        "X-BUILD-TIME",
    }
)


@dataclass
class TocStore:
    """Metadata lines we keep, keyed by their full key (e.g. ``X-Quest-7-S``)."""

    values: dict[str, str] = field(default_factory=dict)
    headers: dict[str, str] = field(default_factory=dict)

    def resolve(self, key: str) -> str | None:
        """Return the stored value for ``key``, reassembling a chunked value if needed."""
        raw = self.values.get(key)
        if raw is None:
            return None
        match = CHUNK_HEADER.match(raw)
        if not match:
            return raw
        parts = int(match.group(1))
        pieces: list[str] = []
        for number in range(1, parts + 1):
            piece = self.values.get(f"{key}-{number}")
            if piece is None:
                raise ValueError(f"{key} declares {parts} parts but part {number} is missing")
            pieces.append(piece)
        return "".join(pieces)


def stream_toc(path: Path) -> TocStore:
    """Read the TOC once, keeping entity metadata lines and the header fields we need."""
    store = TocStore()
    with path.open(encoding="utf-8", errors="strict", newline="") as handle:
        for line in _metadata_lines(handle):
            key, value = line
            if key.startswith(ENTITY_KEY_PREFIXES):
                store.values[key] = value
            elif key in HEADER_KEYS:
                store.headers[key] = value
    return store


def _metadata_lines(handle: Any) -> Iterator[tuple[str, str]]:
    for raw in handle:
        if not raw.startswith("## "):
            continue
        body = raw[3:].rstrip("\r\n")
        if ": " not in body:
            continue
        key, value = body.split(": ", 1)
        if key.startswith("X-l"):
            # Localization blocks: not needed for English names (field 1 already holds them).
            continue
        yield key, value


def decompress(data: bytes) -> tuple[bytes, str]:
    """DecompressString method 1: try zlib, then raw deflate, then gzip. Returns (bytes, method)."""
    attempts = (
        ("zlib", lambda b: zlib.decompress(b)),
        ("raw-deflate", lambda b: zlib.decompress(b, -15)),
        ("gzip", lambda b: gzip.decompress(b)),
    )
    errors: list[str] = []
    for name, fn in attempts:
        try:
            return fn(data), name
        except (zlib.error, OSError) as exc:
            errors.append(f"{name}: {exc}")
    raise ValueError("no decompression method worked: " + "; ".join(errors))


def _decode_b64_cbor(text: str) -> Any:
    return cbor2.loads(base64.b64decode(text))


def _text(value: Any) -> Any:
    """Turn CBOR byte strings (how QuestieDB stores text) into ``str``, recursively."""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    if isinstance(value, list):
        return [_text(item) for item in value]
    if isinstance(value, dict):
        return {_text(key): _text(item) for key, item in value.items()}
    return value


@dataclass
class EntityIds:
    """Decoded ID header for one entity type."""

    ids: list[int]
    method: str
    declared_parts: int


def decode_ids(store: TocStore, schema: EntitySchema) -> EntityIds:
    """Decode ``X-<Entity>-IDS`` into the list of entity IDs."""
    key = schema.prefix.rstrip("-") + "-IDS"
    header = store.values.get(key)
    if header is None:
        raise ValueError(f"missing metadata key {key}")
    match = CHUNK_HEADER.match(header)
    declared = int(match.group(1)) if match else 1
    encoded = store.resolve(key)
    if encoded is None:
        raise ValueError(f"missing metadata key {key}")
    raw, method = decompress(base64.b64decode(encoded))
    ids = cbor2.loads(raw)
    if not isinstance(ids, list):
        raise ValueError(f"{key} did not decode to a list")
    return EntityIds(ids=[int(i) for i in ids], method=method, declared_parts=declared)


@dataclass
class DecodeStats:
    """Counts gathered while decoding one entity type, reported in the manifest."""

    entity: str
    ids: int = 0
    missing_scalar_rows: int = 0
    missing_table_values: int = 0
    array_scalar_rows: int = 0


def _scalar_row(decoded: Any, stats: DecodeStats) -> dict[Any, Any]:
    """Return the scalar row as ``{fieldIndex: value}`` with a ``p`` presence key if present.

    Most rows are CBOR maps. A few are CBOR arrays (placeholder/reused slots such as the
    quest named ``REUSE ME``). Lua reads an array positionally, so element ``i`` is field
    ``i + 1``, and such rows have no presence mask.
    """
    if isinstance(decoded, dict):
        return decoded
    if isinstance(decoded, list):
        stats.array_scalar_rows += 1
        return {position + 1: value for position, value in enumerate(decoded) if value is not None}
    raise ValueError(f"scalar row decoded to {type(decoded).__name__}, expected map or array")


def _presence(row: dict[Any, Any]) -> int:
    value = row.get(b"p", row.get("p", 0))
    return int(value or 0)


def decode_entity(
    store: TocStore, schema: EntitySchema, ids: list[int], stats: DecodeStats
) -> dict[str, dict[str, Any]]:
    """Decode every entity of one type into ``{id: {fieldName: normalizedValue}}``."""
    out: dict[str, dict[str, Any]] = {}
    for entity_id in ids:
        row_text = store.resolve(f"{schema.prefix}{entity_id}-S")
        if row_text is None:
            stats.missing_scalar_rows += 1
            row: dict[Any, Any] = {}
        else:
            row = _scalar_row(cbor2.loads(base64.b64decode(row_text)), stats)
        presence = _presence(row)

        record: dict[str, Any] = {}
        for index in range(1, schema.field_count + 1):
            name = schema.names.get(index)
            if name is None:
                continue
            raw: Any = None
            if index in schema.constant_values:
                raw = None
            elif schema.types.get(index) == "table":
                if (presence >> (index - 1)) & 1:
                    value_text = store.resolve(f"{schema.prefix}{entity_id}-{index}")
                    if value_text is None:
                        stats.missing_table_values += 1
                    else:
                        raw = cbor2.loads(base64.b64decode(value_text))
            else:
                raw = row.get(index)
            raw = _text(raw)
            value = normalize_field(schema, index, raw)
            if value is not None:
                record[name] = value
        out[str(entity_id)] = record
        stats.ids += 1
    return out
