import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

from hooks.test_user_question_guard import question_event

SOURCE = Path(os.environ.get("DISPATCH_TEST_PLUGIN", Path(__file__).resolve().parent.parent))
PYTHON_GUARDS = ("user_question_guard", "skill_gate", "test_scope_guard", "message_scope_guard", "context_usage")
SHELL_GUARDS = ("agent-spawn-guard.sh", "workflow-spawn-guard.sh", "bash-guard.sh", "file-guard.sh",
                "security-filter.sh", "validate-commit.sh", "validate-summary.sh", "validate-frontmatter.sh",
                "state-updater.sh", "deviq-nudge.sh")


class DispatchProject:
    def __init__(self, case):
        temporary = tempfile.TemporaryDirectory(prefix="dispatch-test-")
        case.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.plugin = self.base / "plugin"
        self.root = self.base / "project"
        self.root.mkdir()
        self.planning = self.root / ".lbwc-planning"
        self.planning.mkdir()
        self.home = self.base / "home"
        self.home.mkdir()
        self.scratch = self.base / "tmp"
        self.scratch.mkdir()
        shutil.copytree(SOURCE / "hooks", self.plugin / "hooks", ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copytree(SOURCE / "scripts", self.plugin / "scripts")
        (self.plugin / "templates/agent-roles").mkdir(parents=True)
        shutil.copyfile(SOURCE / "templates/agent-roles/defaults.json", self.plugin / "templates/agent-roles/defaults.json")
        self.environment = {key: value for key, value in os.environ.items()
                            if key not in {"CDPATH", "TMUX", "TMUX_PANE", "LBWC_CONTROL_ROOT"}}
        self.environment.update(CLAUDE_PLUGIN_ROOT=str(self.plugin), LBWC_PLANNING_DIR=str(self.planning),
                                HOME=str(self.home), TMPDIR=str(self.scratch), PYTHONDONTWRITEBYTECODE="1")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, env=self.environment)

    def event(self, tool, tool_input=None) -> dict:
        return {"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": tool_input or {},
                "cwd": str(self.root), "session_id": "dispatch-session"}

    def run(self, data, event="PreToolUse") -> subprocess.CompletedProcess:
        config = json.loads((self.plugin / "hooks/hooks.json").read_text())
        tool = data.get("tool_name", "Write") if isinstance(data, dict) else "Write"
        tool = tool if isinstance(tool, str) and tool else "Write"
        commands = [hook["command"] for entry in config["hooks"][event]
                    if re.fullmatch(entry.get("matcher", ".*"), tool) for hook in entry["hooks"]]
        if len(commands) != 1:
            raise AssertionError(f"Expected one registered command for {event} {tool}, got {commands}")
        arguments = shlex.split(commands[0].replace("${CLAUDE_PLUGIN_ROOT}", str(self.plugin)))
        text = data if isinstance(data, str) else json.dumps(data)
        return subprocess.run(arguments, input=text, capture_output=True, text=True, cwd=self.root,
                              env=self.environment, timeout=9)

    def python_guard(self, name, source) -> None:
        (self.plugin / "hooks" / (name + ".py")).write_text(source)

    def shell_guard(self, name, source) -> None:
        (self.plugin / "scripts" / name).write_text(source)

    def neutralize(self) -> None:
        for name in PYTHON_GUARDS:
            self.python_guard(name, "def verdict(*args): return None\ndef run(*args): pass\n"
                              "def emit_pretool_denial(reason): pass\nEMITTERS = dict()\n"
                              "_dispatch = verdict\nclass DecisionStateError(Exception): pass\n")
        for name in SHELL_GUARDS:
            self.shell_guard(name, "exit 0\n")

    def crash_all(self) -> None:
        for name in PYTHON_GUARDS:
            self.python_guard(name, "raise RuntimeError('injected guard failure')\n")
        for name in SHELL_GUARDS:
            self.shell_guard(name, "exit 1\n")

    def restore_shell(self, name) -> None:
        shutil.copyfile(SOURCE / "scripts" / name, self.plugin / "scripts" / name)

    def manifest(self, entry) -> None:
        (self.planning / ".agent-manifest.json").write_text(json.dumps({"agents": {"engineer": entry}}))

    def engineer(self) -> None:
        self.manifest({"role": "python-engineer", "pair_id": "pair-a", "project_root": str(self.root),
                       "write_allowances": ["src/app.py"]})

    def open_question(self) -> None:
        event = {**question_event("dispatch-session", self.root), "hook_event_name": "PreToolUse"}
        result = self.run(event)
        if result.returncode or result.stdout:
            raise AssertionError(f"Cannot arrange pending decision: {result}")

    def record(self) -> dict:
        from hooks.user_question_guard import DecisionStore
        return DecisionStore(self.planning).record("dispatch-session")

    def count_jq(self) -> None:
        binary = self.base / "bin"
        binary.mkdir()
        self.jq_log = self.base / "jq.log"
        shim = binary / "jq"
        shim.write_text('#!/bin/bash\nsource=nudge\ncase "$*" in\n'
                        '*"--arg source hook"*) source=hook ;;\n'
                        '*"--arg source manifest"*) source=manifest ;;\n'
                        '*"--arg source contract"*) source=contract ;;\nesac\n'
                        'printf "%s\\n" "$source" >> "$DISPATCH_JQ_LOG"\nexec "$DISPATCH_REAL_JQ" "$@"\n')
        shim.chmod(0o755)
        real_jq = shutil.which("jq")
        if real_jq is None:
            raise RuntimeError("Dispatcher JSON batching fixtures require jq on PATH")
        self.environment.update(DISPATCH_JQ_LOG=str(self.jq_log), DISPATCH_REAL_JQ=real_jq,
                                PATH=str(binary) + os.pathsep + os.environ["PATH"])

    def jq_sources(self) -> list:
        return self.jq_log.read_text().splitlines() if self.jq_log.exists() else []

    def jq_calls(self) -> int:
        return len(self.jq_sources())

    def nudge_config(self) -> None:
        (self.plugin / "config").mkdir()
        (self.plugin / "references/deviq-corpus").mkdir(parents=True)
        (self.plugin / "config/deviq-nudges.json").write_text(json.dumps([
            {"pattern": "unrelated", "article": "first"}, {"pattern": "duplicate", "article": "practice"}]))
        (self.plugin / "references/deviq-corpus/index.json").write_text(json.dumps([
            {"id": "practice", "title": "Avoid duplication"}]))


def decision(result) -> str | None:
    return json.loads(result.stdout or "{}").get("hookSpecificOutput", {}).get("permissionDecision")


def warnings(result) -> list:
    return [line for line in result.stderr.splitlines() if "hook warning:" in line]
