"""Klimax pipeline entry point: ``python -m pipeline <command>``.

Every subcommand is a stub for now. Each one is implemented in the phase
that owns it (see docs/PROGRESS.md).
"""

from __future__ import annotations

import argparse
import sys

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
        sub.add_parser(name, help=help_text, description=help_text)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 0
    _help, phase = COMMANDS[args.command]
    print(f"'{args.command}' is not implemented yet (phase {phase}).", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
