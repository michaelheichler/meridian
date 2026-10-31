from __future__ import annotations

import secrets
from pathlib import Path
from typing import cast

if __package__:
    from .decision_common import (
        ACTIVE_STATUSES,
        INVALID_RECORD,
        INVALID_STATE,
        Record,
        Submission,
        require,
    )
    from .decision_io import load_json, record_lock, write_json
    from .decision_layout import DecisionLayout
    from .decision_records import (
        apply_cancel,
        apply_freeform_answer,
        apply_option_answer,
        new_record,
        record_digest,
        validate_record,
        validate_shape,
    )
    from .question_validation import fingerprint
else:
    from decision_common import (
        ACTIVE_STATUSES,
        INVALID_RECORD,
        INVALID_STATE,
        Record,
        Submission,
        require,
    )
    from decision_io import load_json, record_lock, write_json
    from decision_layout import DecisionLayout
    from decision_records import (
        apply_cancel,
        apply_freeform_answer,
        apply_option_answer,
        new_record,
        record_digest,
        validate_record,
        validate_shape,
    )
    from question_validation import fingerprint

STATE_CHANGED = "The user decision state changed. Present a new decision."


class DecisionStore:
    def __init__(self, planning_dir: Path) -> None:
        self.layout = DecisionLayout(planning_dir)
        self.planning_dir = self.layout.planning_dir

    def _record_path(self, session_id: str, create: object) -> Path | None:
        return self.layout.record_path(session_id, create)

    def _read_record(self, session_id: str) -> Record | None:
        path = self._record_path(session_id, create=False)
        if path is None or not path.exists():
            return None
        record = load_json(path)
        validate_record(self.layout, record)
        require(record["session_id"] == session_id, INVALID_RECORD)
        return record

    def _lock(self, session_id: str):
        path = self._record_path(session_id, create=True)
        require(path is not None, INVALID_STATE)
        return record_lock(cast(Path, path))

    def _persist(self, path: Path, record: Record) -> None:
        session_id = record["session_id"]
        require(isinstance(session_id, str), INVALID_RECORD)
        record["transition_id"] = secrets.token_urlsafe(32)
        record["record_digest"] = ""
        record["record_digest"] = record_digest(record)
        transition_id = record["transition_id"]
        authority = self.layout.create_authority_path(session_id, transition_id)
        write_json(authority, _authority_payload(record))
        write_json(path, record)

    def _save(self, session_id: str, record: Record) -> None:
        path = self._record_path(session_id, create=True)
        require(path is not None, INVALID_STATE)
        self._persist(cast(Path, path), record)

    def state(self, session_id: str) -> str:
        record = self._read_record(session_id)
        return "none" if record is None else str(record["status"])

    def record(self, session_id: str) -> Record:
        record = self._read_record(session_id)
        require(record is not None, "The pending user decision record is unavailable.")
        return cast(Record, record)

    def open(self, session_id: str, question: Record) -> None:
        shape = {"mode": "bounded", **question}
        validate_shape(shape)
        state_fingerprint = fingerprint(question, self.planning_dir)
        with self._lock(session_id):
            current = self._read_record(session_id)
            if current and current["status"] in ACTIVE_STATUSES:
                require(
                    current["state_fingerprint"] != state_fingerprint,
                    "A user decision is already pending.",
                )
            self._save(session_id, new_record(session_id, state_fingerprint, shape))

    def answer(self, session_id: str, submission: Submission) -> None:
        with self._lock(session_id):
            current = self.record(session_id)
            record = _expect(current, submission.fingerprint, "pending")
            options = validate_shape(record["response_shape"])["options"]
            if submission.answer in options:
                apply_option_answer(record, submission.answer)
            else:
                apply_freeform_answer(record)
            self._save(session_id, record)

    def resolve_freeform(self, session_id: str, expected: str) -> None:
        with self._lock(session_id):
            current = self.record(session_id)
            record = _expect(current, expected, "awaiting_freeform")
            apply_freeform_answer(record)
            self._save(session_id, record)

    def cancel(self, session_id: str) -> None:
        with self._lock(session_id):
            record = self.record(session_id)
            if record["status"] == "cancelled":
                return
            require(record["status"] in ACTIVE_STATUSES, INVALID_RECORD)
            apply_cancel(record)
            self._save(session_id, record)

    def acknowledge_cancel(self, session_id: str) -> None:
        with self._lock(session_id):
            record = self.record(session_id)
            if record["status"] == "resolved":
                return
            require(record["status"] == "cancelled", INVALID_RECORD)
            record["status"] = "resolved"
            self._save(session_id, record)


def _expect(record: Record, expected: str, status: str) -> Record:
    require(record["state_fingerprint"] == expected, STATE_CHANGED)
    require(record["status"] == status, INVALID_RECORD)
    return record


def _authority_payload(record: Record) -> Record:
    return {
        "record_digest": record["record_digest"],
        "session_id": record["session_id"],
        "transition_id": record["transition_id"],
    }
