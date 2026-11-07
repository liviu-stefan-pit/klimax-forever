"""Klimax pipeline entry point: ``python -m pipeline <command>``.

Every subcommand is a stub for now. Each one is implemented in the phase
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
    "shape": ("Build Horde band packs and travel candidates", "02"),
    "validate": ("Validate route JSON (hard gate)", "03"),
    "compile": ("Compile validated routes into Klimax/Routes/*.lua", "03"),
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
    return parser


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


def _run_extract(questiedb: Path, out_dir: Path) -> int:
    from pipeline.extract.run import format_summary, run_extract

    def progress(message: str) -> None:
        print(f"[extract] {message}", file=sys.stderr)

    try:
        result = run_extract(questiedb=questiedb, out_dir=out_dir, progress=progress)
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
    if args.command == "shape":
        return _run_shape(args)
    _help, phase = COMMANDS[args.command]
    print(f"'{args.command}' is not implemented yet (phase {phase}).", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
