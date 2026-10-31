from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, cast

if __package__:
    from .decision_common import (
        ACTIVE_STATUSES,
        ASK_TOOL,
        DECISION_SCHEMA_VERSION,
        DIGEST_LENGTH,
        INTEGRITY_FAILED,
        INVALID_RECORD,
        MAX_OPTIONS,
        MIN_OPTIONS,
        Record,
        SESSION_PATTERN,
        require,
        utc_timestamp,
    )
    from .decision_io import load_json
    from .decision_layout import DecisionLayout
else:
    from decision_common import (
        ACTIVE_STATUSES,
        ASK_TOOL,
        DECISION_SCHEMA_VERSION,
        DIGEST_LENGTH,
        INTEGRITY_FAILED,
        INVALID_RECORD,
        MAX_OPTIONS,
        MIN_OPTIONS,
        Record,
        SESSION_PATTERN,
        require,
        utc_timestamp,
    )
    from decision_io import load_json
    from decision_layout import DecisionLayout

RECORD_KEYS = frozenset(
    {
        "command",
        "created_at",
        "record_digest",
        "resolved_at",
        "response",
        "response_received_at",
        "response_shape",
        "schema_version",
        "session_id",
        "state_fingerprint",
        "status",
        "transition_id",
    }
)
SHAPE_KEYS = frozenset({"allows_freeform", "mode", "options", "question"})
STATUSES = ACTIVE_STATUSES | {"resolved", "cancelled"}


def record_digest(record: dict[str, Any]) -> str:
    unsigned = {key: value for key, value in record.items() if key != "record_digest"}
    payload = json.dumps(unsigned, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _validate_options(options: object) -> None:
    require(isinstance(options, list), INVALID_RECORD)
    items = cast(list[Any], options)
    require(MIN_OPTIONS <= len(items) <= MAX_OPTIONS, INVALID_RECORD)
    require(all(isinstance(item, str) and item for item in items), INVALID_RECORD)
    require(len(items) == len(set(items)), INVALID_RECORD)


def validate_shape(shape: object) -> dict[str, Any]:
    require(isinstance(shape, dict), INVALID_RECORD)
    checked = cast(dict[str, Any], shape)
    require(set(checked) == SHAPE_KEYS and checked.get("mode") == "bounded", INVALID_RECORD)
    require(isinstance(checked.get("question"), str), INVALID_RECORD)
    _validate_options(checked.get("options"))
    require(isinstance(checked.get("allows_freeform"), bool), INVALID_RECORD)
    return checked


def _validate_identity(record: dict[str, Any]) -> None:
    session_id = record.get("session_id")
    fingerprint = record.get("state_fingerprint")
    transition_id = record.get("transition_id")
    valid_session = isinstance(session_id, str) and SESSION_PATTERN.fullmatch(session_id)
    require(valid_session, INVALID_RECORD)
    require(isinstance(fingerprint, str) and len(fingerprint) == DIGEST_LENGTH, INVALID_RECORD)
    require(isinstance(transition_id, str) and bool(transition_id), INVALID_RECORD)


def _validate_authority(layout: DecisionLayout, record: dict[str, Any]) -> None:
    session_id = cast(str, record["session_id"])
    transition_id = cast(str, record["transition_id"])
    authority = layout.authority_path(session_id, transition_id)
    require(authority is not None, INTEGRITY_FAILED)
    expected = {
        "record_digest": record["record_digest"],
        "session_id": session_id,
        "transition_id": transition_id,
    }
    require(load_json(cast(Path, authority)) == expected, INTEGRITY_FAILED)


def validate_record(layout: DecisionLayout, record: dict[str, Any]) -> None:
    require(set(record) == RECORD_KEYS, INVALID_RECORD)
    require(record.get("schema_version") == DECISION_SCHEMA_VERSION, INVALID_RECORD)
    _validate_identity(record)
    digest = record.get("record_digest")
    require(isinstance(digest, str) and digest == record_digest(record), INTEGRITY_FAILED)
    validate_shape(record.get("response_shape"))
    require(record.get("status") in STATUSES, INVALID_RECORD)
    _validate_authority(layout, record)


def new_record(session_id: str, fingerprint: str, shape: Record) -> Record:
    return {
        "schema_version": DECISION_SCHEMA_VERSION,
        "session_id": session_id,
        "command": ASK_TOOL,
        "state_fingerprint": fingerprint,
        "created_at": utc_timestamp(),
        "response_shape": shape,
        "status": "pending",
        "response": None,
        "response_received_at": None,
        "resolved_at": None,
        "transition_id": "",
        "record_digest": "",
    }


def apply_option_answer(record: dict[str, Any], answer: str) -> None:
    record["status"] = "resolved"
    record["response"] = answer
    record["resolved_at"] = utc_timestamp()


def apply_freeform_answer(record: dict[str, Any]) -> None:
    timestamp = utc_timestamp()
    record["status"] = "resolved"
    record["response"] = {"kind": "freeform", "received": True}
    record["response_received_at"] = timestamp
    record["resolved_at"] = timestamp


def apply_cancel(record: dict[str, Any]) -> None:
    record["status"] = "cancelled"
    record["response"] = {"kind": "cancelled"}
    record["resolved_at"] = utc_timestamp()
