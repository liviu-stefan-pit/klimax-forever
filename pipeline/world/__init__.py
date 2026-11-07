"""World data model and compiler (phase 19, docs/DYNAMIC_GUIDE_PLAN.md s4.1 and s8).

The quest graph plus the curated layer (``data/<faction>/world/corrections.json``) is the source
of truth for the dynamic guide. ``python -m pipeline compile-world`` builds it from ``data/raw``
(QuestieDB extract), ``data/<faction>/travel.json`` and the corrections, checks it with the graph
validator and writes ``Klimax/World/*.lua``:

* ``<Zone>.lua``: one file per compiled zone, registered lazily (the table is built on first use).
* ``Outside.lua``: NPCs and objects that compiled quests reference but whose home zone is not
  compiled yet (for example a Tirisfal quest that ends in Western Plaguelands).
* ``Index.lua``: quest/NPC/object -> zone, zone level ranges, exclusive and equivalent groups.
* ``Travel.lua``: flight nodes, boat/zeppelin docks, zone adjacency and rough costs.

Modules: ``config`` (settings), ``corrections`` (curated layer), ``quests`` (graph builder),
``npcs`` (NPC/object records), ``services`` (roles, hub services, coverage), ``hubs``
(clustering), ``zones`` (zone list, XP-weighted level ranges), ``travel``, ``build``
(orchestration), ``lua`` (deterministic Lua writer), ``validate`` (graph validator), ``report``
(coverage and gaps report) and ``cli``. The compact Lua keys are listed in docs/PRD.md s6.8.
"""
