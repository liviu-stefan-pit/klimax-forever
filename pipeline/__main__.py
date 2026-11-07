"""Klimax pipeline entry point: ``python -m pipeline <command>``.

Subcommands that are not implemented yet are stubs. Each one is implemented in the phase
that owns it (see docs/PROGRESS.md).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from pipeline.extract.run import DEFAULT_OUT, DEFAULT_QUESTIEDB

# name -> (help text, phase that implements it)
COMMANDS: dict[str, tuple[str, str]] = {
    "extract": ("Decode QuestieDB into data/raw/*.json + manifest.json", "01"),
    "game-data": ("Read transport/trainer facts from the installed game's add-ons", "03b"),
    "rxp-crosscheck": ("Write docs/reports/rxp_crosscheck.md (ids and counts only)", "03b"),
    "shape": ("Build Horde band packs and travel candidates", "02"),
    "validate": ("Validate route JSON (hard gate)", "03"),
    "compile": ("Compile validated routes into Klimax/Routes/*.lua", "03"),
    "overview": ("Write docs/ROUTE_OVERVIEW.md from the stitched routes", "05"),
    "gen-rares": ("Write Klimax/Data/Rares.lua (rare NPCs in Horde zones)", "08"),
    "gen-chests": ("Write Klimax/Data/Chests.lua (chest spawns in Horde zones)", "08"),
    "fixture": ("Convert a /klimax dump (SavedVariables) into a JSON test fixture", "18"),
    "diagnose": ("Offline data checks behind the phase 18 diagnosis (read-only)", "18"),
    "refresh": ("extract + shape + diff + validate in one go", "90"),
    "diff-db": ("Diff two raw extracts and list affected bands", "90"),
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m pipeline",
        description="Offline data pipeline for Klimax.",
    )
    sub = parser.add_subparsers(dest="command", metavar="<command>")
    for name, (help_text, _phase) in COMMANDS.items():
        sub_parser = sub.add_parser(name, help=help_text, description=help_text)
        if name == "extract":
            sub_parser.add_argument(
                "--questiedb",
                type=Path,
                default=DEFAULT_QUESTIEDB,
                help="path to the QuestieDB folder (default: %(default)s)",
            )
            sub_parser.add_argument(
                "--out",
                type=Path,
                default=DEFAULT_OUT,
                help="output folder for data/raw (default: %(default)s)",
            )
        if name == "game-data":
            sub_parser.add_argument(
                "--addons",
                type=Path,
                default=None,
                help="Interface/AddOns folder of the installed game (read-only)",
            )
            sub_parser.add_argument(
                "--out", type=Path, default=Path("data/raw/game"), help="output folder"
            )
        if name == "shape":
            sub_parser.add_argument(
                "--faction", default="horde", help="faction id (default: horde)"
            )
            sub_parser.add_argument(
                "--raw", type=Path, default=Path("data/raw"), help="data/raw folder"
            )
            sub_parser.add_argument(
                "--data", type=Path, default=Path("data"), help="output data folder"
            )
            sub_parser.add_argument(
                "--report", action="store_true", help="print the sanity report after building"
            )
            sub_parser.add_argument(
                "--report-only",
                action="store_true",
                help="print the report from existing band files, without rebuilding",
            )
        if name == "validate":
            sub_parser.add_argument(
                "files",
                nargs="*",
                type=Path,
                help="route (*.route.json) or curation (*.curated.json) files; "
                "default: every route in --routes-dir",
            )
            sub_parser.add_argument(
                "--stitched",
                action="store_true",
                help="also check the whole path: next links, band continuity, entry/exit",
            )
            sub_parser.add_argument(
                "--through",
                type=int,
                default=None,
                help="with --stitched: check the path only up to this level and ignore "
                "routes that start at or above it (partial route sets)",
            )
            sub_parser.add_argument("--json", action="store_true", help="machine-readable output")
            sub_parser.add_argument("--no-stats", action="store_true", help="hide the stats block")
            _add_route_paths(sub_parser)
        if name == "overview":
            sub_parser.add_argument("--out", type=Path, default=Path("docs/ROUTE_OVERVIEW.md"))
            sub_parser.add_argument(
                "--through", type=int, default=None, help="only describe levels below this one"
            )
            _add_route_paths(sub_parser)
        if name == "fixture":
            sub_parser.add_argument(
                "savedvars", type=Path, help="WTF/Account/<account>/SavedVariables/Klimax.lua"
            )
            sub_parser.add_argument(
                "--out", type=Path, default=None, help="fixture path (default: tests/fixtures/...)"
            )
            sub_parser.add_argument("--char", default=None, help="dump key 'Name-Realm'")
            sub_parser.add_argument(
                "--keep-name", action="store_true", help="keep the character name and realm"
            )
        if name == "diagnose":
            sub_parser.add_argument(
                "--check",
                action="append",
                default=None,
                help="run only this check (repeatable): scope_gaps, npc_positions, "
                "shadowed_ids, cross_branch_rewards, zone_flow",
            )
            sub_parser.add_argument("--json", action="store_true", help="machine-readable output")
            sub_parser.add_argument("--limit", type=int, default=25, help="lines per check")
            sub_parser.add_argument(
                "--as",
                dest="as_char",
                default=None,
                metavar="RACE/CLASS",
                help="zone_flow for one character only, e.g. Orc/HUNTER",
            )
            _add_route_paths(sub_parser)
        if name == "compile":
            sub_parser.add_argument("--addon", type=Path, default=Path("Klimax"))
            sub_parser.add_argument(
                "--stitched", action="store_true", help="validate with the stitched-path checks"
            )
            _add_route_paths(sub_parser)
    return parser


def _add_route_paths(sub_parser: argparse.ArgumentParser) -> None:
    sub_parser.add_argument("--faction", default="horde", help="faction id (default: horde)")
    sub_parser.add_argument("--raw", type=Path, default=Path("data/raw"), help="data/raw folder")
    sub_parser.add_argument("--data", type=Path, default=Path("data"), help="data folder")
    sub_parser.add_argument(
        "--routes-dir",
        type=Path,
        default=None,
        help="folder with *.route.json (default: routes/<faction>)",
    )


def _run_validate(args: argparse.Namespace) -> int:
    from pipeline.routes.cli import run_validate

    return run_validate(
        args.files,
        stitched=args.stitched,
        as_json=args.json,
        faction=args.faction,
        raw=args.raw,
        data=args.data,
        routes_dir=args.routes_dir or Path("routes") / args.faction,
        show_stats=not args.no_stats,
        through=args.through,
    )


def _run_overview(args: argparse.Namespace) -> int:
    from pipeline.routes.cli import run_overview

    return run_overview(
        faction=args.faction,
        raw=args.raw,
        data=args.data,
        routes_dir=args.routes_dir or Path("routes") / args.faction,
        out=args.out,
        through=args.through,
    )


def _run_compile(args: argparse.Namespace) -> int:
    from pipeline.routes.cli import run_compile

    return run_compile(
        faction=args.faction,
        raw=args.raw,
        data=args.data,
        routes_dir=args.routes_dir or Path("routes") / args.faction,
        addon_dir=args.addon,
        stitched=args.stitched,
    )


def _run_fixture(args: argparse.Namespace) -> int:
    from pipeline.diagnose.fixture import FixtureError, convert_file
    from pipeline.diagnose.savedvars import SavedVariablesError

    try:
        path = convert_file(args.savedvars, args.out, char=args.char, keep_name=args.keep_name)
    except (OSError, FixtureError, SavedVariablesError) as exc:
        print(f"fixture: {exc}", file=sys.stderr)
        return 1
    print(f"wrote {path}")
    return 0


def _run_diagnose(args: argparse.Namespace) -> int:
    import json

    from pipeline.diagnose.data_checks import CHECKS, format_report, load_routes, run_checks
    from pipeline.routes.world import World

    unknown = [c for c in args.check or [] if c not in CHECKS]
    if unknown:
        print(f"diagnose: unknown check(s): {', '.join(unknown)}", file=sys.stderr)
        return 2
    try:
        world = World.load(args.faction, args.raw, args.data)
    except FileNotFoundError as exc:
        print(f"diagnose: {exc} (run extract and shape first)", file=sys.stderr)
        return 2
    as_char = None
    if args.as_char:
        race, _, klass = args.as_char.partition("/")
        if not race or not klass:
            print("diagnose: --as needs RACE/CLASS, e.g. Orc/HUNTER", file=sys.stderr)
            return 2
        as_char = (race, klass.upper())
    routes = load_routes(args.routes_dir or Path("routes") / args.faction)
    results = run_checks(routes, world, args.check, as_char)
    if args.json:
        print(json.dumps(results, indent=1, sort_keys=True))
    else:
        print(format_report(results, args.limit))
    return 0


def _run_shape(args: argparse.Namespace) -> int:
    from pipeline.shape.run import format_report, load_report_from_disk, run_shape

    if args.report_only:
        print(format_report(load_report_from_disk(args.faction, args.data)))
        return 0

    def progress(message: str) -> None:
        print(f"[shape] {message}", file=sys.stderr)

    try:
        result = run_shape(args.faction, args.raw, args.data, progress=progress)
    except FileNotFoundError as exc:
        print(f"shape: {exc} (run `python -m pipeline extract` first)", file=sys.stderr)
        return 1
    print(format_report(result) if args.report else f"{len(result.packs)} packs written")
    return 0


def _run_game_data(args: argparse.Namespace) -> int:
    from pipeline.extract.game_travel import DEFAULT_ADDONS, write_transport
    from pipeline.extract.rxp_guides import write_rxp_quest_ids
    from pipeline.extract.trainer_spells import write_trainer_spells

    addons = args.addons or DEFAULT_ADDONS
    if not addons.is_dir():
        print(f"game-data: {addons} not found (the game must be installed)", file=sys.stderr)
        return 1
    path = write_transport(addons, args.out)
    print(f"wrote {path}")
    print(f"wrote {write_trainer_spells(addons, args.out)}")
    print(f"wrote {write_rxp_quest_ids(addons, args.out)}")
    return 0


def _run_extract(questiedb: Path, out_dir: Path) -> int:
    from pipeline.extract.run import format_summary, run_extract

    def progress(message: str) -> None:
        print(f"[extract] {message}", file=sys.stderr)

    try:
        from pipeline.routes.ui_maps import UI_MAPS_PATH

        result = run_extract(
            questiedb=questiedb, out_dir=out_dir, progress=progress, ui_maps_path=UI_MAPS_PATH
        )
    except FileNotFoundError as exc:
        print(f"extract: {exc}", file=sys.stderr)
        return 1
    print(format_summary(result))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 0
    if args.command == "extract":
        return _run_extract(args.questiedb, args.out)
    if args.command == "game-data":
        return _run_game_data(args)
    if args.command == "rxp-crosscheck":
        from pipeline.shape.rxp_crosscheck import run_crosscheck

        print(f"wrote {run_crosscheck()}")
        return 0
    if args.command == "shape":
        return _run_shape(args)
    if args.command == "validate":
        return _run_validate(args)
    if args.command == "compile":
        return _run_compile(args)
    if args.command == "overview":
        return _run_overview(args)
    if args.command == "fixture":
        return _run_fixture(args)
    if args.command == "diagnose":
        return _run_diagnose(args)
    if args.command == "gen-rares":
        from pipeline.smart.gen import write_rares

        print(f"wrote Klimax/Data/Rares.lua ({write_rares()} rares)")
        return 0
    if args.command == "gen-chests":
        from pipeline.smart.gen import write_chests

        print(f"wrote Klimax/Data/Chests.lua ({write_chests()} chest spawns)")
        return 0
    _help, phase = COMMANDS[args.command]
    print(f"'{args.command}' is not implemented yet (phase {phase}).", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
