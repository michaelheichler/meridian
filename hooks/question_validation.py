from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any, cast

if __package__:
    from .decision_common import (
        ASK_TOOL,
        INVALID_STATE,
        MAX_OPTIONS,
        MIN_OPTIONS,
        Record,
        require,
    )
else:
    from decision_common import (
        ASK_TOOL,
        INVALID_STATE,
        MAX_OPTIONS,
        MIN_OPTIONS,
        Record,
        require,
    )

TECHNICAL_TERMS = re.compile(
    r"\b(api|binary|cli|filesystem|hook|json|regex|runtime|schema|token)\b",
    re.IGNORECASE,
)
MIN_QUESTION_LENGTH = 16
MAX_QUESTION_LENGTH = 500
MIN_HEADER_LENGTH = 2
MAX_HEADER_LENGTH = 80
MIN_DESCRIPTION_LENGTH = 8
MAX_DESCRIPTION_LENGTH = 240
STATE_FILES = ("config.json", "capabilities.json", "routing.json")


def _has_technical_language(value: str) -> bool:
    return bool(TECHNICAL_TERMS.search(value)) or "\n" in value or "`" in value


def _single_question(tool_input: Record) -> Record:
    questions = tool_input.get("questions")
    require(
        isinstance(questions, list)
        and len(questions) == 1
        and isinstance(questions[0], dict),
        "AskUserQuestion must present one decision at a time.",
    )
    return cast(list[Record], questions)[0]


def _validate_wording(wording: object) -> str:
    require(
        isinstance(wording, str)
        and wording.endswith("?")
        and MIN_QUESTION_LENGTH <= len(wording) <= MAX_QUESTION_LENGTH,
        "AskUserQuestion needs one clear, self-contained question.",
    )
    text = cast(str, wording)
    require(
        not _has_technical_language(text),
        "AskUserQuestion must use plain language for the user.",
    )
    return text


def _is_valid_header(header: object) -> bool:
    return (
        isinstance(header, str)
        and MIN_HEADER_LENGTH <= len(header) <= MAX_HEADER_LENGTH
        and not _has_technical_language(header)
    )


def _validate_option(option: object) -> str:
    require(isinstance(option, dict), "AskUserQuestion options are invalid.")
    fields = cast(Record, option)
    label = fields.get("label")
    description = fields.get("description")
    require(
        isinstance(label, str) and 1 <= len(label) <= MAX_HEADER_LENGTH,
        "AskUserQuestion option labels are invalid.",
    )
    require(
        isinstance(description, str)
        and MIN_DESCRIPTION_LENGTH <= len(description) <= MAX_DESCRIPTION_LENGTH,
        "AskUserQuestion options need clear descriptions.",
    )
    require(
        not _has_technical_language(cast(str, label))
        and not _has_technical_language(cast(str, description)),
        "AskUserQuestion options must use plain language for the user.",
    )
    return cast(str, label)


def _validate_options(options: object) -> list[str]:
    require(
        isinstance(options, list) and MIN_OPTIONS <= len(options) <= MAX_OPTIONS,
        "AskUserQuestion needs two to four choices.",
    )
    labels = [_validate_option(option) for option in cast(list[Any], options)]
    require(len(labels) == len(set(labels)), "AskUserQuestion option labels must be unique.")
    require(
        not any(label.strip().lower() == "other" for label in labels),
        "AskUserQuestion must not duplicate the native Other option.",
    )
    return labels


def validate_question(tool_input: object) -> Record:
    require(isinstance(tool_input, dict), "AskUserQuestion input is malformed.")
    question = _single_question(cast(Record, tool_input))
    wording = _validate_wording(question.get("question"))
    header = question.get("header")
    require(header is None or _is_valid_header(header), "AskUserQuestion header is invalid.")
    require(
        question.get("multiSelect") in (None, False),
        "AskUserQuestion must ask for one decision.",
    )
    labels = _validate_options(question.get("options"))
    return {"question": wording, "options": labels, "allows_freeform": True}


def _hash_state_file(path: Path) -> str:
    require(path.is_file() and not path.is_symlink(), INVALID_STATE)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _state_hashes(planning_dir: Path) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for filename in STATE_FILES:
        path = planning_dir / filename
        if path.exists() or path.is_symlink():
            hashes[filename] = _hash_state_file(path)
    return hashes


def fingerprint(question: Record, planning_dir: Path) -> str:
    state = {"cwd": str(planning_dir.parent), **_state_hashes(planning_dir)}
    payload = {"command": ASK_TOOL, "question": question, "state": state}
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()
