import contextlib
import importlib
import io
import json
import signal
import sys
import time

from hook_batch import BashBatch
from hook_output import decode_output, merge_output


QUESTION_TOOLS = "AskUserQuestion Agent TaskCreate TaskUpdate Write Edit NotebookEdit Bash Skill SendMessage Grep Glob"
PRETOOL = (
    (QUESTION_TOOLS, "user_question_guard", 5),
    ("Agent Task TaskCreate", "agent-spawn-guard.sh", 15),
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


class GuardTimeout(BaseException):
    pass


class DispatchTerminated(BaseException):
    pass


def _timeout(_signum, _frame):
    raise GuardTimeout()


def _terminate(_signum, _frame):
    raise DispatchTerminated()


def _python_call(name, text, event):
    module = importlib.import_module(name)
    if name == "context_usage":
        module.run(text)
        return
    if name == "user_question_guard":
        mode = "pretool" if event == "PreToolUse" else "posttool"
        try:
            reason = module._dispatch(text, mode)
        except module.DecisionStateError as error:
            reason = str(error)
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
    except GuardTimeout:
        status = 124
    except Exception:
        status = 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    return status, output.getvalue(), errors.getvalue()


def _warning(name, status):
    sys.stderr.write(f"meridian hook warning: {name} exited {status}, call allowed\n")


def _collect(result, outputs, name):
    status, stdout, stderr = result
    if status != 0:
        sys.stderr.write(stderr)
    if status == 0:
        outputs.extend(decode_output(stdout))
    if status not in (0, 2):
        _warning(name, status)
    return status == 2


class GuardRunner:
    def __init__(self, text, event):
        self.text = text
        self.event = event
        self.batch = None

    def run(self, spec) -> tuple:
        if not spec[1].endswith(".sh"):
            return _python_guard(spec, self.text, self.event)
        deadline = time.monotonic() + spec[2]
        for _attempt in range(2):
            try:
                return self._bash_guard(spec, deadline)
            except Exception:
                self._reset()
        return 1, "", ""

    def _reset(self):
        try:
            self.close()
        except Exception:
            _warning("hook-batch.sh cleanup", 1)

    def _bash_guard(self, spec, deadline):
        if self.batch is not None and self.batch.broken:
            self._reset()
        if self.batch is None:
            self.batch = BashBatch(self.text)
        return self.batch.run(spec[1], max(0, deadline - time.monotonic()))

    def close(self) -> None:
        batch, self.batch = self.batch, None
        if batch is None:
            return
        batch.close()


def _json_denied(outputs):
    for output in outputs:
        specific = output.get("hookSpecificOutput")
        if isinstance(specific, dict) and specific.get("permissionDecision") == "deny":
            return True
    return False


def _execute(runner, specs):
    blocked, outputs, failed = False, [], False
    try:
        for spec in specs:
            result = runner.run(spec)
            blocked = result[0] == 2 or blocked
            _collect(result, outputs, spec[1])
    except (Exception, DispatchTerminated):
        _warning("dispatch.py execution", 1)
        failed = True
    return blocked, outputs, failed


def _finish(blocked, outputs, failed):
    if failed:
        return (2 if blocked or _json_denied(outputs) else 0), {}
    try:
        return (2 if blocked else 0), merge_output(outputs)
    except (Exception, DispatchTerminated):
        _warning("dispatch.py output", 1)
        return (2 if blocked or _json_denied(outputs) else 0), {}


def _dispatch_guards(runner, specs):
    previous = signal.signal(signal.SIGTERM, _terminate)
    blocked, outputs, failed = _execute(runner, specs)
    try:
        runner.close()
    except (Exception, DispatchTerminated):
        _warning("dispatch.py cleanup", 1)
        failed = True
    try:
        return _finish(blocked, outputs, failed)
    finally:
        signal.signal(signal.SIGTERM, previous)


def dispatch(text, event_hint="") -> tuple:
    try:
        data = json.loads(text)
    except ValueError:
        data = {}
    if not isinstance(data, dict):
        data = {}
    event = data.get("hook_event_name")
    if not isinstance(event, str) or event not in EVENTS:
        event = event_hint
    tool = data.get("tool_name")
    if not isinstance(tool, str) or not tool:
        sys.stderr.write("meridian hook warning: dispatch.py invalid routing data, call allowed\n")
        return 0, {}
    specs = [spec for spec in EVENTS.get(event, ()) if tool in spec[0].split()]
    return _dispatch_guards(GuardRunner(text, event), specs)


def main() -> None:
    text = sys.stdin.read()
    status, output = dispatch(text, sys.argv[1] if len(sys.argv) > 1 else "")
    try:
        if output:
            print(json.dumps(output))
    except Exception:
        _warning("dispatch.py output", 1)
        status = 2 if status == 2 or _json_denied([output]) else 0
    raise SystemExit(status)


if __name__ == "__main__":
    main()
