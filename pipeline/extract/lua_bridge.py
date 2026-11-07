"""Small helpers around lupa for running QuestieDB Lua files offline.

QuestieDB files are plain Lua that expect the add-on varargs ``(addonName, LibQuestieDB)``.
We run them in a fresh Lua state with a caller-owned namespace table, then convert the
resulting Lua tables into plain Python data.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from lupa import LuaRuntime


def new_runtime() -> LuaRuntime:
    """Return a Lua 5.x runtime with standard libraries and tuple unpacking enabled."""
    return LuaRuntime(unpack_returned_tuples=True, encoding="utf-8")


_LOADFILE = "function(p) local f, e = loadfile(p); if not f then error(e, 0) end; return f end"


def run_lua_file(lua: LuaRuntime, path: Path, namespace: Any) -> None:
    """Execute a Lua file as an add-on chunk: ``chunk("QuestieDB", namespace)``.

    Raises whatever Lua raises (``lupa.LuaError``) so callers can record skips.
    """
    chunk = lua.eval(_LOADFILE)(str(path))
    chunk("QuestieDB", namespace)


def lua_to_python(value: Any) -> Any:
    """Convert a lupa value into plain Python data.

    * Lua sequences ``{1..n}`` become ``list``.
    * Other tables become ``dict`` (integer keys are preserved as ``int``).
    * Lua functions are dropped (returned as ``None``); they are code, not data.
    """
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if hasattr(value, "items"):
        pairs = list(value.items())
        if pairs and all(isinstance(key, int) for key, _ in pairs):
            keys = sorted(key for key, _ in pairs)
            if keys == list(range(1, len(keys) + 1)):
                ordered = dict(pairs)
                return [lua_to_python(ordered[key]) for key in keys]
        return {key: lua_to_python(item) for key, item in pairs}
    return None
