"""Command-line drivers for ``python -m pipeline validate`` and ``compile``."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from pipeline.routes.compile_routes import (
    CompileError,
    CompileRefused,
    compile_faction,
    write_result,
)
from pipeline.routes.validate_route import (
    ERROR,
    Issue,
    Report,
    RouteValidator,
    format_report,
    global_stitch_reports,
    load_route_dir,
    validate_curated,
)
from pipeline.routes.world import World


def _load_world(faction: str, raw: Path, data: Path) -> World | None:
    try:
        return World.load(faction, raw, data)
    except FileNotFoundError as exc:
        print(
            f"error: {exc}. Run `python -m pipeline extract` and `python -m pipeline shape` first.",
            file=sys.stderr,
        )
        return None


def _read_json(path: Path) -> tuple[Any, str | None]:
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except OSError as exc:
        return None, f"cannot read {path}: {exc.strerror or exc}"
    except json.JSONDecodeError as exc:
        return None, f"{path} is not valid JSON: {exc}"


def run_validate(
    files: list[Path],
    *,
    stitched: bool,
    as_json: bool,
    faction: str,
    raw: Path,
    data: Path,
    routes_dir: Path,
    show_stats: bool = True,
) -> int:
    world = _load_world(faction, raw, data)
    if world is None:
        return 2
    if not files:
        files = sorted(routes_dir.glob("*.route.json"))
    if not files:
        print(f"no route files found (looked in {routes_dir})", file=sys.stderr)
        return 2

    reports: list[Report] = []
    routes: dict[str, dict[str, Any]] = {}
    by_file: dict[str, str] = {}
    for path in files:
        if path.name.endswith(".curated.json"):
            payload, problem = _read_json(path)
            issues = (
                [Issue(ERROR, "E_JSON", problem)]
                if problem
                else validate_curated(payload, world)
            )
            reports.append(Report(route_id=path.name, file=str(path), issues=issues))
            continue
        payload, problem = _read_json(path)
        if problem or not isinstance(payload, dict):
            reports.append(
                Report(
                    route_id=path.name,
                    file=str(path),
                    issues=[Issue(ERROR, "E_JSON", problem or f"{path} must hold a JSON object.")],
                )
            )
            continue
        rid = payload.get("id", path.name)
        if rid in routes and not (routes[rid].get("sample") or payload.get("sample")):
            reports.append(
                Report(
                    route_id=str(rid),
                    file=str(path),
                    issues=[Issue(ERROR, "E_DUP_ID", f"id '{rid}' is also used by {by_file[rid]}.")],
                )
            )
            continue
        if rid in routes and payload.get("sample"):
            continue  # a real route with this id wins over the sample
        routes[str(rid)] = payload
        by_file[str(rid)] = str(path)

    store = dict(routes)
    if not stitched:
        for rid, route in load_route_dir(routes_dir).items():
            store.setdefault(rid, route)
    reports.extend(_validate_selected(routes, store, world, by_file, stitched))

    if as_json:
        print(
            json.dumps(
                [
                    {
                        "route": r.route_id,
                        "file": r.file,
                        "ok": r.ok,
                        "issues": [i.as_dict() for i in r.issues],
                        "stats": r.stats,
                    }
                    for r in reports
                ],
                indent=2,
                sort_keys=True,
            )
        )
    else:
        for report in reports:
            print(format_report(report, stats=show_stats))
        bad = sum(1 for r in reports if not r.ok)
        print(f"\n{len(reports)} route file(s) checked, {bad} failed.")
    return 1 if any(not r.ok for r in reports) else 0


def _validate_selected(
    selected: dict[str, dict[str, Any]],
    store: dict[str, dict[str, Any]],
    world: World,
    by_file: dict[str, str],
    stitched: bool,
) -> list[Report]:
    """Validate the selected routes against the wider store (siblings for stitching)."""
    validator = RouteValidator(world, store, stitched=stitched)
    reports = [validator.validate(route, by_file.get(rid, "")) for rid, route in selected.items()]
    if stitched:
        reports.extend(global_stitch_reports(store, world))
    return reports


def run_compile(
    *,
    faction: str,
    raw: Path,
    data: Path,
    routes_dir: Path,
    addon_dir: Path,
    stitched: bool,
) -> int:
    world = _load_world(faction, raw, data)
    if world is None:
        return 2
    try:
        result = compile_faction(faction, routes_dir, addon_dir, world, stitched=stitched)
    except CompileRefused as exc:
        for report in exc.reports:
            if not report.ok:
                print(format_report(report, stats=False))
        print(f"\ncompile refused: {exc}", file=sys.stderr)
        return 1
    except CompileError as exc:
        print(f"compile error: {exc}", file=sys.stderr)
        return 1
    write_result(result, faction, addon_dir)
    warnings = sum(len(r.warnings) for r in result.reports)
    for path in sorted(result.files):
        print(f"wrote {path.as_posix()}")
    for path in result.removed:
        print(f"removed stale {path.as_posix()}")
    print(f"compiled {len(result.reports)} route(s); {warnings} warning(s).")
    return 0
