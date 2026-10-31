from __future__ import annotations

import re
from typing import Optional

BRACE_LIMIT = 256
NUMERIC_RANGE = re.compile(r"(-?\d+)\.\.(-?\d+)(?:\.\.(-?\d+))?")
LETTER_RANGE = re.compile(r"([A-Za-z])\.\.([A-Za-z])(?:\.\.(-?\d+))?")


class ExpansionTooComplex(Exception):
    pass


def _matching_close(value: str, start: int) -> int:
    depth = 0
    for index in range(start, len(value)):
        depth += (value[index] == "{") - (value[index] == "}")
        if depth == 0:
            return index
    return -1


def _split_top(inner: str) -> list[str]:
    parts: list[str] = []
    depth = 0
    current = ""
    for char in inner:
        if char == "," and depth == 0:
            parts.append(current)
            current = ""
            continue
        depth += (char == "{") - (char == "}")
        current += char
    return [*parts, current]


def _step_size(text: Optional[str]) -> int:
    step = abs(int(text)) if text else 1
    if step == 0:
        raise ExpansionTooComplex("zero step in brace range")
    return step


def _series(first: int, last: int, step: int) -> list[int]:
    if abs(last - first) // step + 1 > BRACE_LIMIT:
        raise ExpansionTooComplex("brace range too large")
    direction = 1 if last >= first else -1
    return [first + direction * step * index for index in range(abs(last - first) // step + 1)]


def _padding(first_text: str, last_text: str) -> int:
    padded = any(len(text.lstrip("-")) > 1 and text.lstrip("-")[0] == "0" for text in (first_text, last_text))
    return max(len(first_text), len(last_text)) if padded else 0


def _numeric_items(match: re.Match) -> list[str]:
    first_text, last_text = match.group(1), match.group(2)
    numbers = _series(int(first_text), int(last_text), _step_size(match.group(3)))
    width = _padding(first_text, last_text)
    return [f"{number:0{width}d}" for number in numbers]


def _letter_items(match: re.Match) -> list[str]:
    first, last = ord(match.group(1)), ord(match.group(2))
    return [chr(code) for code in _series(first, last, _step_size(match.group(3)))]


def _range_items(inner: str) -> list[str]:
    numeric = NUMERIC_RANGE.fullmatch(inner)
    if numeric:
        return _numeric_items(numeric)
    letters = LETTER_RANGE.fullmatch(inner)
    if letters:
        return _letter_items(letters)
    if ".." in inner:
        raise ExpansionTooComplex("unparseable brace range")
    return []


def _group_parts(inner: str) -> list[str]:
    parts = _split_top(inner)
    if len(parts) > BRACE_LIMIT:
        raise ExpansionTooComplex("brace list too large")
    return parts if len(parts) > 1 else _range_items(inner)


def _first_group(value: str) -> Optional[tuple[int, int, list[str]]]:
    start = value.find("{")
    while start != -1:
        end = _matching_close(value, start)
        parts = _group_parts(value[start + 1 : end]) if end != -1 else []
        if parts:
            return start, end, parts
        start = value.find("{", start + 1)
    return None


def expand_braces(value: str) -> list[str]:
    group = _first_group(value)
    if group is None:
        return [value]
    start, end, parts = group
    prefix, suffix = value[:start], value[end + 1 :]
    expanded = [item for part in parts for item in expand_braces(prefix + part + suffix)]
    if len(expanded) > BRACE_LIMIT:
        raise ExpansionTooComplex("brace expansion too large")
    return expanded
