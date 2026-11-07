# Klimax

> *Klimax* (Ancient Greek κλῖμαξ): "ladder" or "staircase", a climb one step at a time.

Klimax is a minimal, on-screen leveling guide for **WoW Forever**. It tells a solo player what to do next, at a relaxed pace. It is not a speedrun guide.

- **No pointless walking.** Quests are grouped into geographic clusters. You pick up 3–5 quests, clear an area in one pass, and hand them in together.
- **You keep getting stronger.** Routes chase quest rewards that are real upgrades for your class.
- **Logistics are built in.** Inns, flight paths, trainers, repairs and hearthstone use.
- **You are never stuck.** Skip any step, or re-sync to your level with one click.

The data is built offline by a Python pipeline. The in-game add-on is self-contained, with no dependencies and no network access.

**Status:** pre-alpha. Phase 00 (bootstrap) is complete. See [`docs/PROGRESS.md`](docs/PROGRESS.md). Horde is the first faction, levels 1–60.

## Repository layout

| Path | Purpose |
|---|---|
| `docs/` | PRD, playbook, phase prompts and progress log |
| `pipeline/` | Offline Python pipeline (`python -m pipeline`) |
| `data/` | Derived data: raw extract (generated), Horde travel graph, bands, curated decisions |
| `routes/` | Route JSON, the source of truth for every route |
| `Klimax/` | The add-on folder, copied into `Interface/AddOns` |
| `tests/lua/` | Lua specs and WoW API stubs |

## Setup

```bash
python -m venv .venv
.venv/Scripts/python.exe -m pip install -e ".[dev]"
.venv/Scripts/python.exe -m pipeline --help
```

## Credits and licence

Klimax is built on **[QuestieDB](https://github.com/Questie/QuestieDB)** by the Questie team and its data contributors. The quest, NPC, object and item data comes from QuestieDB (Forever flavour). Route data is derived from it.

QuestieDB is needed locally to build the data. It is **not committed to this repository**. Place a copy in `QuestieDB/` (git-ignored). The pipeline runs offline against that folder.

Klimax is released under the **GNU General Public License v3.0**. See [`LICENSE`](LICENSE).
