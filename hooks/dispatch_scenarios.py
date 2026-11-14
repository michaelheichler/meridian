import json
import shutil
import subprocess
import time
from pathlib import Path

from hooks.dispatch_fixtures import SOURCE, warnings
from hooks.dispatch_faults import FAULT_WARNINGS, arrange_fault

AGGREGATION_CASES = ("exit-deny", "json-deny-crash", "contexts", "process-timeout", "nested-deadline", *FAULT_WARNINGS)


def shell_output(payload, status=0) -> str:
    return "printf '%s\\n' " + "'" + json.dumps(payload) + "'\nexit " + str(status) + "\n"


def context(text) -> dict:
    return {"hookSpecificOutput": {"additionalContext": text}, "systemMessage": text}


def arrange_aggregation(space, kind) -> tuple:
    later = context("later")
    space.shell_guard("security-filter.sh", shell_output(later))
    if kind in FAULT_WARNINGS:
        return arrange_fault(space, kind)
    if kind == "exit-deny":
        space.shell_guard("file-guard.sh", shell_output(context("first"), 2))
        return space.event("Write"), (2, None)
    if kind == "json-deny-crash":
        space.python_guard("scope_guard", "def verdict(*args): raise RuntimeError('injected')\n")
        space.python_guard("skill_gate", "import json\ndef verdict(*args): return 'policy denial'\n"
                           "def emit_pretool_denial(reason):\n print(json.dumps({'hookSpecificOutput': "
                           "{'permissionDecision': 'deny', 'permissionDecisionReason': reason}}))\n")
        return space.event("Write"), (0, "deny")
    if kind == "contexts":
        space.shell_guard("file-guard.sh", shell_output(context("first")))
        space.python_guard("skill_gate", "import json\ndef verdict(*args):\n print(json.dumps(" + repr(context("python")) + "))\n")
        return space.event("Write"), (0, None)
    return arrange_timeout(space, kind)


def arrange_timeout(space, kind) -> tuple:
    if kind == "nested-deadline":
        shutil.copyfile(SOURCE / "hooks/user_question_guard.py", space.plugin / "hooks/real_question_guard.py")
        space.python_guard("user_question_guard", "import time\nfrom real_question_guard import *\n"
                           "from real_question_guard import _dispatch as real_dispatch\n"
                           "def _dispatch(text, mode):\n real_dispatch(text, mode)\n time.sleep(5.7)\nverdict = _dispatch\n")
        return space.event("Bash", {"command": "cat plain.txt"}), (0, None)
    space.shell_guard("file-guard.sh", 'sleep 5.7 &\nprintf "%s\\n" "$!" > "$DISPATCH_CHILD_PID"\nwait\n')
    space.environment["DISPATCH_CHILD_PID"] = str(space.base / "child.pid")
    return space.event("Write", {"file_path": "src/app.py"}), (0, None)


def aggregation_case(space, kind) -> tuple:
    event, expected = arrange_aggregation(space, kind)
    if kind == "nested-deadline":
        space.shell_guard("bash-guard.sh", shell_output(context("later")))
    result = space.run(event)
    payload = json.loads(result.stdout or "{}")
    expected_context = {"malformed-permission": "first\nlater", "contexts": "python\nfirst\nlater"}.get(kind, "later")
    child_alive = running_child(space) if kind == "process-timeout" else False
    actual = (result.returncode, payload.get("hookSpecificOutput", {}).get("permissionDecision"),
              payload.get("systemMessage"), payload.get("hookSpecificOutput", {}).get("additionalContext"), child_alive, len(warnings(result)))
    warning_count = FAULT_WARNINGS.get(kind, int(kind in {"json-deny-crash", "process-timeout", "nested-deadline"}))
    return result, actual, (*expected, expected_context, expected_context, False, warning_count)


def running_child(space) -> bool:
    identifier = (space.base / "child.pid").read_text().strip()
    result = subprocess.run(["ps", "-o", "stat=", "-p", identifier], capture_output=True, text=True, check=False)
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")


def policy_case(space, row) -> tuple:
    if row.startswith("protected-"):
        return space.run(space.event("Write", {"file_path": row[len("protected-"):]})), None, None
    if row.startswith("pending-"):
        space.open_question()
        tool = row[len("pending-"):]
        result = space.run(space.event(tool, {"file_path": "src/app.py", "command": "touch app.py"}))
        return result, "deny", None
    if row in {"answer", "stale-answer"}:
        return answer_case(space, row)
    return engineer_case(space, row)


def answer_case(space, row) -> tuple:
    space.open_question()
    if row == "stale-answer":
        (space.planning / "config.json").write_text('{"review":"changed"}')
    answer = space.event("AskUserQuestion", {"answers": {"Which review pace should this project use?": "Careful"}})
    result = space.run({**answer, "hook_event_name": "PostToolUse"}, "PostToolUse")
    record = space.record()
    if row == "answer" and record["response"] != "Careful":
        raise AssertionError("The registered answer hook lost the selected answer")
    return result, None, record["status"]


def engineer_case(space, row) -> tuple:
    space.engineer()
    if row == "engineer-message":
        event = {**space.event("SendMessage", {"to": "main", "message": "progress"}), "agent_id": "engineer"}
        result = space.run(event)
        standalone = subprocess.run(["python3", str(space.plugin / "hooks/message_scope_guard.py")],
                                    input=json.dumps(event), cwd=space.root, env=space.environment,
                                    capture_output=True, text=True, check=True)
        if json.loads(result.stdout) != json.loads(standalone.stdout):
            raise AssertionError("Dispatcher changed the engineer message policy")
        return result, "deny", None
    read = {**space.event("Read", {"file_path": "skills-bundle/practice/SKILL.md"}), "agent_id": "engineer"}
    arranged = space.run(read)
    if arranged.returncode or arranged.stdout:
        raise AssertionError(f"Cannot arrange required reading: {arranged}")
    return space.run({**space.event("Write", {"file_path": "src/app.py"}), "agent_id": "engineer"}), None, None


def batching_case(space, kind, value) -> tuple:
    if kind == "file":
        return file_batch_case(space, value)
    if kind == "manifest":
        return manifest_batch_case(space, value)
    if kind == "contract":
        return contract_batch_case(space, value)
    return nudge_batch_case(space, value)


def file_batch_case(space, path) -> tuple:
    space.restore_shell("file-guard.sh")
    space.manifest({"role": "python-engineer", "project_root": str(space.root),
                    "write_allowances": ["src/app.py", "src/tab\tname.py", ""]})
    space.count_jq()
    result = space.run({**space.event("Write", {"file_path": path}), "agent_id": "engineer"})
    expected = 2 if path in {"src/line\nbreak.py", "src/other.py"} else 0
    return result.returncode, expected, result, 2


def manifest_batch_case(space, path) -> tuple:
    space.restore_shell("file-guard.sh")
    space.manifest({"role": "python-engineer", "project_root": str(space.root),
                    "write_allowances": ["src/from-newline.py\nsrc/extra.py", "src/from-tab\tname.py", ""]})
    space.count_jq()
    result = space.run({**space.event("Write", {"file_path": path}), "agent_id": "engineer"})
    return result.returncode, 2 if path == "src/other.py" else 0, result, 2


def contract_batch_case(space, path) -> tuple:
    space.restore_shell("file-guard.sh")
    script = str(space.plugin / "scripts/task-contract.sh")
    issued = subprocess.run(["bash", script, "issue", str(space.root), "scope-check", "--command", "test",
                             "--role", "python-engineer", "--team", "solo", "--job", "scope validation",
                             "--write-allowance", "src/app.py", "--write-allowance", "src/tab\tname.py"],
                            cwd=space.root, env=space.environment, capture_output=True, text=True, check=True)
    contract_path = issued.stdout.strip()
    contract = json.loads(Path(contract_path).read_text())
    subprocess.run(["bash", script, "state", str(space.root), contract["contract_id"], "dispatched"],
                   cwd=space.root, env=space.environment, capture_output=True, text=True, check=True)
    space.manifest({"role": "python-engineer", "project_root": str(space.root),
                    "write_allowances": ["src/app.py", "src/tab\tname.py"], "contract_path": contract_path,
                    "contract_id": contract["contract_id"], "contract_digest": contract["contract_digest"],
                    "task_identity": contract["task_identity"]})
    space.count_jq()
    result = space.run({**space.event("Write", {"file_path": path}), "agent_id": "engineer"})
    return result.returncode, 2 if path == "src/other.py" else 0, result, 3


def nudge_batch_case(space, content) -> tuple:
    space.restore_shell("deviq-nudge.sh")
    space.nudge_config()
    state = space.planning / "deviq/.nudge-last"
    recent = content == "cooldown"
    if recent:
        state.parent.mkdir()
        state.write_text(str(int(time.time())))
        content = "duplicate code"
    before = state.read_text() if state.exists() else None
    event = {**space.event("Write", {"content": content}), "hook_event_name": "PostToolUse"}
    expected = nudge_oracle(space, event, recent)
    space.count_jq()
    result = space.run(event, "PostToolUse")
    unchanged = not recent or state.read_text() == before
    return (result.returncode, json.loads(result.stdout or "{}"), state.exists(), unchanged), (0, expected, content == "duplicate code" or recent, True), result, 1


def nudge_oracle(space, event, recent) -> dict:
    planning = space.base / "oracle-planning"
    planning.mkdir()
    if recent:
        (planning / "deviq").mkdir()
        (planning / "deviq/.nudge-last").write_text(str(int(time.time())))
    oracle = subprocess.run(["bash", str(space.plugin / "scripts/deviq-nudge.sh")], input=json.dumps(event),
                            cwd=space.root, env={**space.environment, "MERIDIAN_PLANNING_DIR": str(planning)},
                            capture_output=True, text=True, check=True)
    return json.loads(oracle.stdout or "{}")
