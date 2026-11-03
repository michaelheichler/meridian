from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Optional, cast

if __package__:
    from . import tmux_restrictions
    from .decision_common import (
        ACTIVE_STATUSES,
        ASK_TOOL,
        INVALID_RECORD,
        SESSION_PATTERN,
        DecisionStateError,
        PendingDecisionError,
        Record,
        Submission,
        require,
    )
    from .decision_store import DecisionStore
    from .guard_paths import has_protected_decision_path, planning_directory
    from .question_validation import fingerprint, validate_question
else:
    import tmux_restrictions
    from decision_common import (
        ACTIVE_STATUSES,
        ASK_TOOL,
        INVALID_RECORD,
        SESSION_PATTERN,
        DecisionStateError,
        PendingDecisionError,
        Record,
        Submission,
        require,
    )
    from decision_store import DecisionStore
    from guard_paths import has_protected_decision_path, planning_directory
    from question_validation import fingerprint, validate_question

__all__ = ["DecisionStateError", "DecisionStore", "PendingDecisionError", "main", "verdict"]

INSPECTION_TOOLS = {"Read", "Glob", "Grep"}
PENDING_ORCHESTRATION_REASON = (
    "A user decision is pending. Inspection may continue, but orchestration "
    "and mutation must wait."
)
READ_DECISION_ARGUMENTS = 3
AGENT_KEYS = (
    "agent_id",
    "agentId",
    "agent_type",
    "agentType",
    "subagent_type",
    "subagentType",
)
MALFORMED_INPUT = "Hook error: malformed hook JSON input."
RESERVED_RUNTIME = "Decision runtime access is reserved for trusted hook transitions."
Verdict = Optional[str]


def _pretool_denial(reason: str) -> str:
    return json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }
    )


def _posttool_context(reason: str) -> str:
    return json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": reason,
            }
        }
    )


def _stop_block(reason: str) -> str:
    return json.dumps({"decision": "block", "reason": reason})


def _write_output(payload: str) -> None:
    sys.stdout.write(f"{payload}\n")


def _event(stdin_text: str) -> tuple[Optional[Record], Optional[str]]:
    try:
        data = json.loads(stdin_text)
    except json.JSONDecodeError:
        return None, MALFORMED_INPUT
    if not isinstance(data, dict):
        return None, MALFORMED_INPUT
    return data, None


def _session_id(data: Record) -> Optional[str]:
    value = data.get("session_id")
    if isinstance(value, str) and SESSION_PATTERN.fullmatch(value):
        return value
    return None


def _first_text(source: Record, keys: tuple[str, ...]) -> Optional[str]:
    for key in keys:
        value = source.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _agent_identifier(data: Record) -> Optional[str]:
    found = _first_text(data, AGENT_KEYS)
    tool_input = data.get("tool_input")
    if found or not isinstance(tool_input, dict):
        return found
    return _first_text(tool_input, (*AGENT_KEYS, "name"))


def _record_for_current_state(
    store: DecisionStore, session_id: str
) -> tuple[Optional[Record], Optional[str]]:
    try:
        record = store.record(session_id)
        shape = record["response_shape"]
        require(isinstance(shape, dict), INVALID_RECORD)
        keys = ("question", "options", "allows_freeform")
        current = fingerprint({key: shape[key] for key in keys}, store.planning_dir)
        require(
            record["state_fingerprint"] == current,
            "The user decision state changed. Present a new decision.",
        )
    except (DecisionStateError, KeyError) as error:
        return None, str(error)
    return record, None


def _is_blocked_while_pending(tool_name: str) -> bool:
    return tool_name not in INSPECTION_TOOLS and tool_name != ASK_TOOL


def _pretool_context(data: Record) -> Any:
    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input")
    if not isinstance(tool_name, str) or not tool_name:
        return "Hook error: malformed PreToolUse JSON input."
    if not isinstance(tool_input, dict):
        return "Hook error: malformed PreToolUse JSON input."
    try:
        planning_dir = planning_directory(data.get("cwd"))
    except DecisionStateError as error:
        return str(error)
    if has_protected_decision_path(data, planning_dir):
        return RESERVED_RUNTIME
    store = DecisionStore(planning_dir) if planning_dir else None
    return tool_name, store, _session_id(data)


def _open_question(data: Record, store: DecisionStore, session_id: str) -> Verdict:
    if _agent_identifier(data) and not tmux_restrictions.question_allowed():
        return (
            "AskUserQuestion is reserved for the main session. "
            "Return a user_decision_required handoff instead."
        )
    store.open(session_id, validate_question(data.get("tool_input")))
    return None


def _store_reason(data: Record, store: DecisionStore, session_id: str) -> Verdict:
    tool_name = cast(str, data.get("tool_name"))
    pending = store.state(session_id) in ACTIVE_STATUSES
    if pending and _is_blocked_while_pending(tool_name):
        return PENDING_ORCHESTRATION_REASON
    if tool_name == ASK_TOOL:
        return _open_question(data, store, session_id)
    return None


def _missing_session_reason(tool_name: str) -> Verdict:
    if tool_name == ASK_TOOL or _is_blocked_while_pending(tool_name):
        return "A valid session id is required for user-decision state."
    return None


def _pretool(data: Record) -> Verdict:
    if data.get("tool_name") == ASK_TOOL:
        reason = tmux_restrictions.denial(data)
        if reason:
            return reason
    context = _pretool_context(data)
    if isinstance(context, str):
        return context
    tool_name, store, session_id = context
    if store is None:
        return None
    if session_id is None:
        return _missing_session_reason(tool_name)
    try:
        return _store_reason(data, store, session_id)
    except DecisionStateError as error:
        return str(error)


def _answer_map(data: Record) -> Optional[Record]:
    for container in (data.get("tool_response"), data.get("tool_input"), data):
        if isinstance(container, dict) and isinstance(container.get("answers"), dict):
            return container["answers"]
    return None


def _is_error_payload(data: Record) -> bool:
    response = data.get("tool_response")
    nested = isinstance(response, dict) and response.get("is_error") is True
    return data.get("is_error") is True or nested


def _submitted_answer(
    store: DecisionStore, session_id: str, data: Record
) -> Optional[Submission]:
    answers = _answer_map(data)
    record, error = _record_for_current_state(store, session_id)
    if answers is None or error is not None or record is None:
        return None
    answer = answers.get(record["response_shape"]["question"])
    if isinstance(answer, str) and not _is_error_payload(data):
        return Submission(answer, str(record["state_fingerprint"]))
    return None


def _required_store(data: Record) -> tuple[DecisionStore, str]:
    planning_dir = planning_directory(data.get("cwd"))
    session_id = _session_id(data)
    require(planning_dir is not None and session_id is not None, INVALID_RECORD)
    return DecisionStore(cast(Path, planning_dir)), cast(str, session_id)


def _posttool(data: Record) -> Verdict:
    if data.get("tool_name") != ASK_TOOL:
        return None
    try:
        store, session_id = _required_store(data)
        if store.state(session_id) not in ACTIVE_STATUSES:
            return None
        submitted = _submitted_answer(store, session_id, data)
        if submitted is None:
            store.cancel(session_id)
        else:
            store.answer(session_id, submitted)
    except DecisionStateError as error:
        return str(error)
    return None


def _apply_prompt(store: DecisionStore, session_id: str) -> Verdict:
    status = store.state(session_id)
    if status == "cancelled":
        store.acknowledge_cancel(session_id)
    if status != "awaiting_freeform":
        return None
    record, error = _record_for_current_state(store, session_id)
    if error:
        return error
    require(record is not None, INVALID_RECORD)
    store.resolve_freeform(session_id, str(cast(Record, record)["state_fingerprint"]))
    return None


def _prompt(data: Record) -> Verdict:
    try:
        planning_dir = planning_directory(data.get("cwd"))
        session_id = _session_id(data)
        prompt = data.get("prompt")
        if planning_dir is None or not isinstance(prompt, str) or not prompt.strip():
            return None
        require(session_id is not None, INVALID_RECORD)
        return _apply_prompt(DecisionStore(planning_dir), cast(str, session_id))
    except DecisionStateError as error:
        return str(error)


def _stop(data: Record) -> Verdict:
    try:
        planning_dir = planning_directory(data.get("cwd"))
        if planning_dir is None:
            return None
        session_id = _session_id(data)
        require(
            session_id is not None,
            "A valid session id is required for user-decision state. Stop is blocked.",
        )
        store = DecisionStore(planning_dir)
        if store.state(cast(str, session_id)) in ACTIVE_STATUSES:
            store.cancel(cast(str, session_id))
    except DecisionStateError as error:
        return (
            "The pending user decision record is invalid: "
            f"{error} Stop is blocked until it is repaired."
        )
    return None


HANDLERS = {"pretool": _pretool, "posttool": _posttool, "prompt": _prompt, "stop": _stop}
EMITTERS = {
    "pretool": _pretool_denial,
    "posttool": _posttool_context,
    "stop": _stop_block,
}


def _dispatch(stdin_text: str, event_name: str) -> Verdict:
    data, error = _event(stdin_text)
    if error:
        raise ValueError(error)
    handler = HANDLERS.get(event_name)
    return handler(data or {}) if handler else None


def verdict(stdin_text: str, event_name: str) -> Verdict:
    try:
        return _dispatch(stdin_text, event_name)
    except DecisionStateError as error:
        return str(error)
    except Exception:
        warning = f"meridian hook warning: user_question_guard {event_name} failed"
        sys.stderr.write(f"{warning}, call allowed\n")
        return None


def _read_decision(args: list[str]) -> int:
    if len(args) != READ_DECISION_ARGUMENTS or args[0] not in {"state", "get"}:
        return 2
    command, planning_text, session_id = args
    try:
        store = DecisionStore(Path(planning_text))
        payload = (
            store.state(session_id) if command == "state" else store.record(session_id)
        )
    except DecisionStateError as error:
        sys.stderr.write(f"pending-decision: {error}\n")
        return 2
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    _write_output(payload if isinstance(payload, str) else encoded)
    return 0


def _read_stdin() -> str:
    try:
        return sys.stdin.read()
    except (OSError, UnicodeDecodeError):
        return ""


def main() -> None:
    event_name = sys.argv[1] if len(sys.argv) > 1 else ""
    if event_name == "decision-read":
        raise SystemExit(_read_decision(sys.argv[2:]))
    reason = verdict(_read_stdin(), event_name)
    emitter = EMITTERS.get(event_name)
    if reason is not None and emitter is not None:
        _write_output(emitter(reason))


if __name__ == "__main__":
    main()
