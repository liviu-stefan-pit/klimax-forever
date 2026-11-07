"""Read a WoW SavedVariables file (plain Lua table literals) without running Lua.

The client writes ``Name = { ["key"] = value, ... }`` assignments with strings, numbers, booleans
and nested tables, plus ``-- [n]`` comments after array items. ``parse_savedvariables`` returns a
``{name: value}`` dict. Tables whose keys are exactly 1..n become lists, every other table a dict
(keys stay ``int`` or ``str``). An empty table becomes an empty dict.
"""

from __future__ import annotations

import re
from typing import Any

_NUMBER = re.compile(r"-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)")
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_ESCAPES = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    "a": "\a",
    "b": "\b",
    "f": "\f",
    "v": "\v",
    "\\": "\\",
    '"': '"',
    "'": "'",
    "\n": "\n",
}


class SavedVariablesError(ValueError):
    """The text is not a SavedVariables file this parser understands."""


class _Parser:
    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0

    # ---- low level -------------------------------------------------------------------------

    def error(self, message: str) -> SavedVariablesError:
        line = self.text.count("\n", 0, self.pos) + 1
        return SavedVariablesError(f"line {line}: {message}")

    def skip(self) -> None:
        text = self.text
        while self.pos < len(text):
            ch = text[self.pos]
            if ch in " \t\r\n﻿":
                self.pos += 1
            elif text.startswith("--[[", self.pos):
                end = text.find("]]", self.pos + 4)
                self.pos = len(text) if end < 0 else end + 2
            elif text.startswith("--", self.pos):
                end = text.find("\n", self.pos)
                self.pos = len(text) if end < 0 else end + 1
            else:
                return

    def peek(self) -> str:
        self.skip()
        return self.text[self.pos] if self.pos < len(self.text) else ""

    def expect(self, token: str) -> None:
        self.skip()
        if not self.text.startswith(token, self.pos):
            raise self.error(f"expected {token!r}")
        self.pos += len(token)

    # ---- values ----------------------------------------------------------------------------

    def value(self) -> Any:
        ch = self.peek()
        if ch == "{":
            return self.table()
        if ch in "\"'":
            return self.string()
        if self.text.startswith("[[", self.pos) or self.text.startswith("[=", self.pos):
            return self.long_string()
        for word, result in (("true", True), ("false", False), ("nil", None)):
            if self.text.startswith(word, self.pos) and not _NAME.match(
                self.text, self.pos + len(word)
            ):
                self.pos += len(word)
                return result
        match = _NUMBER.match(self.text, self.pos)
        if match:
            self.pos = match.end()
            raw = match.group(0)
            if "x" in raw.lower():
                return int(raw, 16)
            if re.fullmatch(r"-?\d+", raw):
                return int(raw)
            return float(raw)
        raise self.error("expected a value")

    def string(self) -> str:
        quote = self.text[self.pos]
        self.pos += 1
        out: list[str] = []
        text = self.text
        while True:
            if self.pos >= len(text):
                raise self.error("unterminated string")
            ch = text[self.pos]
            if ch == quote:
                self.pos += 1
                return "".join(out)
            if ch == "\\":
                nxt = text[self.pos + 1 : self.pos + 2]
                digits = re.match(r"\d{1,3}", text[self.pos + 1 : self.pos + 4])
                if digits:
                    out.append(chr(int(digits.group(0))))
                    self.pos += 1 + len(digits.group(0))
                    continue
                if nxt not in _ESCAPES:
                    raise self.error(f"unknown escape \\{nxt}")
                out.append(_ESCAPES[nxt])
                self.pos += 2
                continue
            out.append(ch)
            self.pos += 1

    def long_string(self) -> str:
        match = re.compile(r"\[(=*)\[").match(self.text, self.pos)
        if not match:
            raise self.error("bad long string")
        close = "]" + match.group(1) + "]"
        end = self.text.find(close, match.end())
        if end < 0:
            raise self.error("unterminated long string")
        body = self.text[match.end() : end]
        self.pos = end + len(close)
        return body[1:] if body.startswith("\n") else body

    def table(self) -> Any:
        self.expect("{")
        entries: list[tuple[Any, Any]] = []
        next_index = 1
        while True:
            ch = self.peek()
            if ch == "}":
                self.pos += 1
                break
            if ch == "[" and not self.text.startswith("[[", self.pos):
                self.pos += 1
                key = self.value()
                self.expect("]")
                self.expect("=")
                entries.append((key, self.value()))
            else:
                name = _NAME.match(self.text, self.pos)
                after = name.end() if name else self.pos
                rest = self.text[after:].lstrip(" \t")
                if name and rest.startswith("=") and not rest.startswith("=="):
                    self.pos = after
                    self.expect("=")
                    entries.append((name.group(0), self.value()))
                else:
                    entries.append((next_index, self.value()))
                    next_index += 1
            sep = self.peek()
            if sep in ",;":
                self.pos += 1
            elif sep != "}":
                raise self.error("expected ',' or '}'")
        return _shape(entries)

    # ---- file ------------------------------------------------------------------------------

    def file(self) -> dict[str, Any]:
        out: dict[str, Any] = {}
        while self.peek():
            name = _NAME.match(self.text, self.pos)
            if not name:
                raise self.error("expected a variable name")
            self.pos = name.end()
            self.expect("=")
            out[name.group(0)] = self.value()
        return out


def _shape(entries: list[tuple[Any, Any]]) -> Any:
    data = {key: value for key, value in entries if value is not None}
    keys = list(data)
    if keys and all(isinstance(k, int) and not isinstance(k, bool) for k in keys):
        if sorted(keys) == list(range(1, len(keys) + 1)):
            return [data[i] for i in range(1, len(keys) + 1)]
    return data


def parse_savedvariables(text: str) -> dict[str, Any]:
    """Parse the text of a SavedVariables file into ``{variable name: value}``."""
    return _Parser(text).file()
