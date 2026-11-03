import json
import shlex

FALLBACK_EVENTS = {"event-null": None, "event-list": [], "event-integer": 7, "event-empty": ""}
FAULT_WARNINGS = {"malformed-permission": 0, "crash-output": 1, "timeout-output": 1,
                  "caught-oserror": 1, "question-handler-crash": 1, "runner-recovery": 0,
                  "unreadable-deny": 1, "unreadable-allow": 1, "missing-event": 0, "object-path": 0,
                  **dict.fromkeys(FALLBACK_EVENTS, 0)}


def arrange_fault(space, kind) -> tuple:
    if kind == "malformed-permission":
        payload = {"hookSpecificOutput": {"permissionDecision": [], "additionalContext": "first"}, "systemMessage": "first"}
        space.python_guard("skill_gate", "import json\ndef verdict(*args):\n print(json.dumps(" + repr(payload) + "))\n")
        space.shell_guard("file-guard.sh", "exit 2\n")
        return space.event("Write"), (2, None)
    if kind in {"crash-output", "timeout-output"}:
        return failed_output(space, kind)
    if kind == "question-handler-crash":
        return question_handler_crash(space)
    if kind in {"unreadable-deny", "unreadable-allow"}:
        status = 2 if kind == "unreadable-deny" else 0
        space.shell_guard("file-guard.sh", 'rm -f "$TMPDIR"/meridian-hooks-*/stdout\nexit ' + str(status) + '\n')
        return space.event("Write"), (status, None)
    if kind == "caught-oserror":
        space.python_guard("skill_gate", "import time\ndef verdict(*args):\n try:\n  time.sleep(5.7)\n except OSError:\n  pass\n")
        return space.event("Write"), (0, None)
    if kind == "runner-recovery":
        runner = space.plugin / "scripts/hook-batch.sh"
        marker = shlex.quote(str(space.base / "runner-failed"))
        runner.write_text("if [ ! -e " + marker + " ]; then\n touch " + marker + "\n exit 1\nfi\n" + runner.read_text())
        return space.event("Write"), (0, None)
    return routing_fault(space, kind)


def question_handler_crash(space) -> tuple:
    from hooks.dispatch_fixtures import SOURCE
    space.python_guard("user_question_guard", (SOURCE / "hooks/user_question_guard.py").read_text())
    space.python_guard("decision_store", "class DecisionStore:\n def __init__(self, *args):\n  raise RuntimeError('injected store failure')\n")
    return space.event("Write"), (0, None)


def routing_fault(space, kind) -> tuple:
    space.restore_shell("file-guard.sh")
    event = space.event("Write", {"file_path": "../outside.py"})
    if kind == "missing-event":
        del event["hook_event_name"]
    elif kind in FALLBACK_EVENTS:
        event["hook_event_name"] = FALLBACK_EVENTS[kind]
    else:
        event["tool_input"]["file_path"] = {"directory": "src", "name": "app.py"}
    return event, (2, None)


def failed_output(space, kind) -> tuple:
    payload = {"hookSpecificOutput": {"permissionDecision": "deny", "additionalContext": "discarded"}, "systemMessage": "discarded"}
    ending = "exit 1\n" if kind == "crash-output" else "sleep 5.7\n"
    space.shell_guard("file-guard.sh", "printf '%s\\n' " + shlex.quote(json.dumps(payload)) + "\n" + ending)
    return space.event("Write"), (0, None)
