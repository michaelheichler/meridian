import json


PERMISSION_PRIORITY = {"allow": 0, "ask": 1, "defer": 2, "deny": 3}


def decode_output(text) -> list:
    try:
        payload = json.loads(text)
        return [payload] if isinstance(payload, dict) else []
    except ValueError:
        return []


def _append(target, key, value):
    if key in target and target[key] and value:
        target[key] = str(target[key]) + "\n" + str(value)
        return
    if key not in target or value:
        target[key] = value


def _permission(current, incoming):
    decision = incoming.get("permissionDecision")
    previous = current.get("permissionDecision")
    if not isinstance(decision, str) or decision not in PERMISSION_PRIORITY:
        return
    if PERMISSION_PRIORITY[decision] > PERMISSION_PRIORITY.get(previous, -1):
        current["permissionDecision"] = decision
        current.pop("permissionDecisionReason", None)
        current.update({key: incoming[key] for key in ("permissionDecisionReason",)
                        if key in incoming})
        return
    if decision == previous and "permissionDecisionReason" in incoming:
        _append(current, "permissionDecisionReason", incoming["permissionDecisionReason"])


def _specific_field(current, key, value):
    if key == "additionalContext":
        _append(current, key, value)
        return
    if key not in {"permissionDecision", "permissionDecisionReason"}:
        current[key] = value


def _specific(target, incoming):
    current = target.setdefault("hookSpecificOutput", {})
    _permission(current, incoming)
    for key, value in incoming.items():
        _specific_field(current, key, value)


def _field(result, output, key):
    value = output[key]
    if key == "hookSpecificOutput" and isinstance(value, dict):
        _specific(result, value)
        return
    if key == "systemMessage":
        _append(result, key, value)
        return
    if key == "continue":
        result[key] = result.get(key, True) and value
        return
    if key == "decision" and result.get(key) == "block":
        return
    if key == "reason" and output.get("decision") == "block":
        _append(result, key, value)
        return
    result[key] = value


def merge_output(outputs) -> dict:
    result = {}
    for output in outputs:
        for key in output:
            _field(result, output, key)
    return result
