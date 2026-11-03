import contextlib
import importlib
import io
import json
import signal
import sys

from hook_batch import BashBatch
from hook_output import decode_output, merge_output


QUESTION_TOOLS = "AskUserQuestion Agent TaskCreate TaskUpdate Write Edit NotebookEdit Bash Skill SendMessage Grep Glob"
PRETOOL = (
    (QUESTION_TOOLS, "user_question_guard", 5),
    ("Agent TaskCreate", "agent-spawn-guard.sh", 15),
    ("Workflow", "workflow-spawn-guard.sh", 15),
    ("Write Edit NotebookEdit Read Glob", "skill_gate", 5),
    ("Write Edit NotebookEdit", "test_scope_guard", 5),
    ("SendMessage", "message_scope_guard", 5),
    ("Bash", "bash-guard.sh", 5),
    ("Write Edit NotebookEdit", "file-guard.sh", 5),
    ("Read Glob Grep Write Edit", "security-filter.sh", 5),
)
POSTTOOL = (
    ("AskUserQuestion", "user_question_guard", 5),
    ("Bash", "validate-commit.sh", 5),
    ("Bash Write Edit", "context_usage", 5),
    ("Write Edit", "validate-summary.sh", 5),
    ("Write Edit", "validate-frontmatter.sh", 5),
    ("Write Edit", "state-updater.sh", 5),
    ("Write Edit", "deviq-nudge.sh", 5),
)
EVENTS = {"PreToolUse": PRETOOL, "PostToolUse": POSTTOOL}


def _timeout(_signum, _frame):
    raise TimeoutError("guard timed out")


def _python_call(name, text, event):
    module = importlib.import_module(name)
    if name == "context_usage":
        module.run(text)
        return
    if name == "user_question_guard":
        mode = "pretool" if event == "PreToolUse" else "posttool"
        reason = module.verdict(text, mode)
        if reason is not None:
            print(module.EMITTERS[mode](reason))
        return
    reason = module.verdict(text)
    if reason is not None:
        importlib.import_module("skill_gate").emit_pretool_denial(reason)


def _python_guard(spec, text, event):
    _, name, timeout = spec
    output, errors = io.StringIO(), io.StringIO()
    status = 0
    previous = signal.signal(signal.SIGALRM, _timeout)
    try:
        signal.setitimer(signal.ITIMER_REAL, timeout)
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            _python_call(name, text, event)
    except SystemExit as error:
        status = error.code if isinstance(error.code, int) else 1
    except Exception as error:
        status = 124 if isinstance(error, TimeoutError) else 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    return status, output.getvalue(), errors.getvalue()


def _warning(name, status):
    sys.stderr.write(f"meridian hook warning: {name} exited {status}, call allowed\n")


def _collect(result, outputs, name):
    status, stdout, stderr = result
    sys.stderr.write(stderr)
    outputs.extend(decode_output(stdout))
    if status not in (0, 2):
        _warning(name, status)
    return status == 2


class GuardRunner:
    def __init__(self, text, event):
        self.text = text
        self.event = event
        self.batch = None
        self.failed = False

    def run(self, spec) -> tuple:
        if not spec[1].endswith(".sh"):
            return _python_guard(spec, self.text, self.event)
        if self.failed:
            return 1, "", ""
        try:
            if self.batch is None:
                self.batch = BashBatch(self.text)
            return self.batch.run(spec[1], spec[2])
        except Exception:
            self.failed = True
            return 1, "", ""

    def close(self) -> None:
        if self.batch is not None:
            self.batch.close()


def dispatch(text, event_hint="") -> tuple:
    try:
        data = json.loads(text)
    except ValueError:
        data = {}
    if not isinstance(data, dict):
        data = {}
    event = data.get("hook_event_name")
    tool = data.get("tool_name")
    if (not isinstance(event, str) or not event
            or not isinstance(tool, str) or not tool
            or (event_hint and event_hint != event)):
        sys.stderr.write("meridian hook warning: dispatch.py invalid routing data, call allowed\n")
        return 0, {}
    specs = [spec for spec in EVENTS.get(event, ()) if tool in spec[0].split()]
    outputs = []
    blocked = False
    runner = GuardRunner(text, event)
    try:
        for spec in specs:
            blocked = _collect(runner.run(spec), outputs, spec[1]) or blocked
    finally:
        runner.close()
    return (2 if blocked else 0), merge_output(outputs)


def main() -> None:
    text = sys.stdin.read()
    status, output = dispatch(text, sys.argv[1] if len(sys.argv) > 1 else "")
    if output:
        print(json.dumps(output))
    raise SystemExit(status)


if __name__ == "__main__":
    main()
