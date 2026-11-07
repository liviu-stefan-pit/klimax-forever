# Klimax — agent instructions

Klimax is a relaxed, solo-friendly leveling guide add-on for WoW Forever (Horde first, levels 1–60, Alliance later). It is built from an offline Python pipeline that turns QuestieDB data into route JSON, which is then compiled into a self-contained Lua add-on. Read `docs/PRD.md` and `docs/PLAYBOOK.md` before making design decisions.

## Rules

- **The quest graph plus the curated layer is the source of truth** (approved 2026-11-07, `docs/DYNAMIC_GUIDE_PLAN.md` §3). The graph is built from QuestieDB by `python -m pipeline compile-world`; the curated layer is `data/<faction>/world/corrections.json` (and, from phase 25, the curated spine). The band routes in `routes/<faction>/*.route.json` are now **seed knowledge and test references**, still validated. Everything under `Klimax/Routes/` and `Klimax/World/` is generated. Never hand-edit it.
- **Never modify `QuestieDB/`.** It is read-only input. It is git-ignored and must not be committed.
- **Always run the validators after touching data**: `python -m pipeline validate <file>` for routes, `python -m pipeline validate --world` for the world graph (also fails when `Klimax/World` is stale; rebuild with `python -m pipeline compile-world`).
- **Keep the add-on dependency-free and taint-free.** No libraries, no external add-on dependencies, no network, and no calls to protected functions.
- **Update `docs/PROGRESS.md` at the end of each phase**, including decisions in its Decisions log.
- Ask before downloading anything (QuestieDB, packages outside the declared dependencies, Lua tooling).

## Layout

- `pipeline/`: Python 3.11+ package (`extract`, `shape`, `routes`, `world`, `diagnose`, `tests`).
- `data/raw/` (generated, git-ignored), `data/horde/` (travel graph, bands, curated decisions, `world/corrections.json`).
- `routes/horde/`: band route JSON (seed knowledge and test references).
- `Klimax/`: the shippable add-on folder.
- `tests/lua/`: busted specs and WoW API stubs.

## Commands

Python (run from the repo root, using `.venv`):

```bash
.venv/Scripts/python.exe -m pip install -e ".[dev]"   # install / refresh dependencies
.venv/Scripts/python.exe -m pytest                     # tests
.venv/Scripts/python.exe -m ruff check pipeline        # lint
.venv/Scripts/python.exe -m pipeline --help            # list pipeline subcommands
```

Lua (Lua 5.1 via Scoop, luacheck 1.2.0, busted 2.1.2; see `docs/PROGRESS.md`):

```bash
luacheck Klimax          # lint; must report zero warnings
tests/lua/busted.cmd tests/lua   # unit specs (phase 06 onward); wrapper sets LUA_PATH
```

## Style

- Python: ruff, line length 100, type hints on public functions.
- Lua: Lua 5.1 (WoW). Globals are declared in `.luacheckrc`. Keep UI strings in `Klimax/Locale/enUS.lua`.
- Output must be deterministic: sorted JSON keys and stable IDs.
