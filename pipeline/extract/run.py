"""Phase 01 orchestration: QuestieDB -> ``data/raw/*.json`` + ``manifest.json``.

Outputs (sorted keys, stable IDs, UTF-8, trailing newline):

* ``quests.json``, ``npcs.json``, ``objects.json``, ``items.json``: ``{id: {fieldName: value}}``
  using QuestieDB's read-back rules (see :mod:`pipeline.extract.normalize`). Quests also get
  ``rewardItemIds``, the inverse of ``items.questRewards``.
* ``xp.json``: ``{questId: [level, xp]}``.
* ``zones.json``: zone maps and the zone name enum.
* ``manifest.json``: provenance, counts, sha256 of each output, corrections applied/skipped.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from pipeline.extract import corrections as corrections_mod
from pipeline.extract import support as support_mod
from pipeline.extract.decode_toc import (
    DecodeStats,
    decode_entity,
    decode_ids,
    stream_toc,
)
from pipeline.extract.schema import EntitySchema, load_schemas

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_QUESTIEDB = REPO_ROOT / "QuestieDB"
DEFAULT_OUT = REPO_ROOT / "data" / "raw"
TOC_NAME = "QuestieDB_Forever.toc"

ENTITY_OUTPUTS: dict[str, str] = {
    "Quest": "quests.json",
    "Npc": "npcs.json",
    "Object": "objects.json",
    "Item": "items.json",
}


@dataclass
class ExtractResult:
    """What one run produced. Returned to the CLI for the summary table."""

    out_dir: Path
    counts: dict[str, int]
    outputs: dict[str, dict[str, Any]]
    manifest: dict[str, Any]
    stats: dict[str, DecodeStats] = field(default_factory=dict)


def sha256_file(path: Path) -> str:
    """Digest of a file, read in chunks so large outputs stay out of memory."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _jsonable(value: Any) -> Any:
    """Make mapping keys strings (JSON requires it) without changing the data."""
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_jsonable(item) for item in value]
    return value


def dumps(data: Any) -> str:
    """Deterministic JSON: sorted keys, two-space indent, UTF-8 text, trailing newline."""
    return json.dumps(_jsonable(data), sort_keys=True, indent=2, ensure_ascii=False) + "\n"


def derive_quest_reward_items(items: dict[str, dict[str, Any]]) -> dict[str, list[int]]:
    """Invert ``items.questRewards``: quest X gets every item that lists X as a reward."""
    inverse: dict[int, set[int]] = {}
    for item_id, record in items.items():
        for quest_id in record.get("questRewards", []) or []:
            inverse.setdefault(int(quest_id), set()).add(int(item_id))
    return {str(quest_id): sorted(item_ids) for quest_id, item_ids in inverse.items()}


def git_head(repo: Path) -> str:
    """Current commit of the extractor, or ``unknown`` outside a git checkout."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return result.stdout.strip()


def run_extract(
    questiedb: Path = DEFAULT_QUESTIEDB,
    out_dir: Path = DEFAULT_OUT,
    progress: Callable[[str], None] = lambda message: None,
) -> ExtractResult:
    """Decode the vendored QuestieDB and write all outputs. Returns the result summary."""
    toc = questiedb / TOC_NAME
    if not toc.is_file():
        raise FileNotFoundError(f"{toc} not found; QuestieDB is a local input (see README)")

    progress("reading schemas from src/meta")
    schemas = load_schemas(questiedb, sha256_file)

    progress("streaming the TOC once")
    store = stream_toc(toc)
    headers = store.headers

    entities: dict[str, dict[str, dict[str, Any]]] = {}
    stats: dict[str, DecodeStats] = {}
    compression: dict[str, str] = {}
    declared_parts: dict[str, int] = {}
    for entity, schema in schemas.items():
        progress(f"decoding {entity} entities")
        ids = decode_ids(store, schema)
        compression[entity] = ids.method
        declared_parts[entity] = ids.declared_parts
        entity_stats = DecodeStats(entity=entity)
        stats[entity] = entity_stats
        entities[entity] = decode_entity(store, schema, ids.ids, entity_stats)
        _check_id_count(entity, ids.ids, entities[entity])

    progress("deriving quest reward items")
    rewards = derive_quest_reward_items(entities["Item"])
    for quest_id, record in entities["Quest"].items():
        if quest_id in rewards:
            record["rewardItemIds"] = rewards[quest_id]

    progress("inventorying corrections")
    correction_report = corrections_mod.inventory(questiedb)

    progress("parsing support data")
    support_report = support_mod.SupportReport()
    xp = support_mod.parse_xp(questiedb / "support" / "Forever" / "QuestXP" / "xpDB-classic.lua")
    zones = support_mod.load_zone_maps(questiedb, support_report)

    out_dir.mkdir(parents=True, exist_ok=True)
    datasets: dict[str, Any] = {
        "quests.json": entities["Quest"],
        "npcs.json": entities["Npc"],
        "objects.json": entities["Object"],
        "items.json": entities["Item"],
        "xp.json": xp,
        "zones.json": zones,
    }
    outputs: dict[str, dict[str, Any]] = {}
    for filename, data in datasets.items():
        path = out_dir / filename
        path.write_text(dumps(data), encoding="utf-8", newline="\n")
        entries = (
            sum(len(section) for section in data.values())
            if filename == "zones.json"
            else len(data)
        )
        outputs[filename] = {"sha256": sha256_file(path), "entries": entries}

    counts = {
        "quests": len(entities["Quest"]),
        "npcs": len(entities["Npc"]),
        "objects": len(entities["Object"]),
        "items": len(entities["Item"]),
        "xp": len(xp),
        "zones": sum(support_report.zone_sections.values()),
    }

    manifest = {
        "questiedb": {
            "version": headers.get("Version"),
            "build_commit": headers.get("X-BUILD-COMMIT"),
            "contract_version": headers.get("X-Contract-Version"),
            "flavor": headers.get("X-Flavor"),
            "mode": headers.get("X-Mode"),
        },
        "extractor_commit": git_head(REPO_ROOT),
        "compression": {
            "method": "DecompressString method 1: zlib, then raw deflate, then gzip",
            "used": compression,
        },
        "entities": {
            entity: {
                "count": len(entities[entity]),
                "ids_header_parts": declared_parts[entity],
                "missing_scalar_rows": stats[entity].missing_scalar_rows,
                "missing_table_values": stats[entity].missing_table_values,
            }
            for entity in schemas
        },
        "schemas": {
            entity: {
                "source": schema.source_file,
                "sha256": schema.source_sha256,
                "fieldCount": schema.field_count,
            }
            for entity, schema in schemas.items()
        },
        "corrections": correction_report.to_manifest(),
        "support": {
            "skipped": support_report.skipped,
            "sections": dict(sorted(support_report.zone_sections.items())),
        },
        "outputs": dict(sorted(outputs.items())),
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(dumps(manifest), encoding="utf-8", newline="\n")

    return ExtractResult(
        out_dir=out_dir,
        counts=counts,
        outputs=outputs,
        manifest=manifest,
        stats=stats,
    )


def _check_id_count(entity: str, ids: list[int], decoded: dict[str, Any]) -> None:
    if len(set(ids)) != len(ids):
        raise ValueError(f"{entity} ID header contains duplicate IDs")
    if len(decoded) != len(ids):
        raise ValueError(f"{entity}: decoded {len(decoded)} records for {len(ids)} IDs")


def format_summary(result: ExtractResult) -> str:
    """Plain-text summary table for the CLI."""
    rows = [("output", "entries", "sha256 (first 12)")]
    for filename, info in result.outputs.items():
        rows.append((filename, str(info["entries"]), info["sha256"][:12]))
    widths = [max(len(row[i]) for row in rows) for i in range(3)]
    lines = ["  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)) for row in rows]
    lines.insert(1, "  ".join("-" * width for width in widths))
    skipped = result.manifest["corrections"]["skipped"] + result.manifest["support"]["skipped"]
    lines.append("")
    lines.append(
        f"compression: {', '.join(sorted(set(result.manifest['compression']['used'].values())))}"
    )
    lines.append(
        f"corrections applied: {len(result.manifest['corrections']['applied'])}, "
        f"skipped: {len(skipped)}"
    )
    for item in skipped:
        lines.append(f"  skipped {item.get('file')}: {item.get('error', '')[:120]}")
    return "\n".join(lines)


__all__ = [
    "DEFAULT_OUT",
    "DEFAULT_QUESTIEDB",
    "ExtractResult",
    "EntitySchema",
    "derive_quest_reward_items",
    "dumps",
    "format_summary",
    "run_extract",
    "sha256_file",
]
