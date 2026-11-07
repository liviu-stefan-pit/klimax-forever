"""Drivers for ``python -m pipeline compile-world`` and ``python -m pipeline validate --world``."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from pipeline.world.build import WorldModel, build_world, load_inputs
from pipeline.world.config import DEFAULT_ZONES, WorldConfig
from pipeline.world.corrections import CorrectionsError
from pipeline.world.lua import sync_toc, world_files, write_files
from pipeline.world.report import coverage_report
from pipeline.world.validate import GraphReport, format_graph_report, validate_world
from pipeline.world.zones import ZoneError

DEFAULT_REPORT = Path("docs/reports/world_coverage.md")


def _build(faction: str, raw: Path, data: Path, zones: list[str] | None) -> WorldModel | None:
    config = WorldConfig(faction=faction, zones=tuple(zones) if zones else DEFAULT_ZONES)
    try:
        raw_data, travel, corrections = load_inputs(raw, data, faction)
        return build_world(raw_data, travel, corrections, config)
    except FileNotFoundError as exc:
        print(f"error: {exc}. Run `python -m pipeline extract` and `shape` first.", file=sys.stderr)
    except (CorrectionsError, ZoneError) as exc:
        print(f"error: {exc}", file=sys.stderr)
    return None


def _print(report: GraphReport, as_json: bool) -> None:
    if as_json:
        print(
            json.dumps(
                {
                    "issues": [i.as_dict() for i in report.issues],
                    "ok": report.ok,
                    "stats": report.stats,
                },
                indent=2,
                sort_keys=True,
            )
        )
    else:
        print(format_graph_report(report))


def run_validate_world(
    *,
    faction: str,
    raw: Path,
    data: Path,
    addon_dir: Path,
    zones: list[str] | None,
    as_json: bool,
) -> int:
    """Validate the graph and check that ``Klimax/World`` matches a fresh compile."""
    model = _build(faction, raw, data, zones)
    if model is None:
        return 2
    files = world_files(model, addon_dir / "World")
    report = validate_world(model, files, check_disk=True)
    _print(report, as_json)
    return 0 if report.ok else 1


def run_compile_world(
    *,
    faction: str,
    raw: Path,
    data: Path,
    addon_dir: Path,
    zones: list[str] | None,
    report_path: Path | None,
) -> int:
    model = _build(faction, raw, data, zones)
    if model is None:
        return 2
    out_dir = addon_dir / "World"
    files = world_files(model, out_dir)
    report = validate_world(model, files)
    if not report.ok:
        print(format_graph_report(report), file=sys.stderr)
        print("\ncompile-world refused: the graph validator found errors.", file=sys.stderr)
        return 1
    removed = write_files(files, out_dir)
    for path in sorted(files):
        print(f"wrote {path.as_posix()} ({len(files[path].encode('utf-8')) // 1024} KB)")
    for path in removed:
        print(f"removed stale {path.as_posix()}")
    toc = addon_dir / "Klimax.toc"
    if toc.exists() and sync_toc(toc, model):
        print(f"updated {toc.as_posix()}")
    if report_path is not None:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(coverage_report(model, report), encoding="utf-8", newline="\n")
        print(f"wrote {report_path.as_posix()}")
    quests = sum(len(model.tables[z.ui_map]["quests"]) for z in model.zones)
    print(
        f"compiled {len(model.zones)} zone(s), {quests} quests; graph: "
        f"{len(report.errors)} error(s), {len(report.warnings)} warning(s)."
    )
    return 0
