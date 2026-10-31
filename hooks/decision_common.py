from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Any, NamedTuple

Record = dict[str, Any]
ASK_TOOL = "AskUserQuestion"
SESSION_PATTERN = re.compile(r"[A-Za-z0-9._-]{1,128}")
MIN_OPTIONS = 2
MAX_OPTIONS = 4
DECISION_SCHEMA_VERSION = 2
DIGEST_LENGTH = 64
ACTIVE_STATUSES = frozenset({"pending", "awaiting_freeform"})
INVALID_STATE = "The pending user decision state is invalid."
INVALID_RECORD = "The pending user decision record is invalid."
INTEGRITY_FAILED = "The pending user decision record integrity check failed."


class Submission(NamedTuple):
    answer: str
    fingerprint: str


class DecisionStateError(RuntimeError):
    pass


class PendingDecisionError(DecisionStateError):
    pass


def require(condition: object, message: str) -> None:
    if not condition:
        raise DecisionStateError(message)


def is_physical_directory(path: Path) -> bool:
    return (
        path.is_dir()
        and not path.is_symlink()
        and all(not parent.is_symlink() for parent in path.parents)
    )


def is_present(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def utc_timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
