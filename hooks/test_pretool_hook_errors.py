import json
import subprocess
import sys
import tempfile
import unittest
from itertools import product
from pathlib import Path

from hooks import skill_gate

HOOK_FILES = ("skill_gate.py", "message_scope_guard.py", "test_scope_guard.py")


def run_hook(filename: str, stdin_text: str, mode: str = "") -> subprocess.CompletedProcess[str]:
    arguments = [mode] if mode else []
    return subprocess.run(
        [sys.executable, str(Path(__file__).parent / filename), *arguments],
        input=stdin_text, capture_output=True, text=True, check=False,
    )


def project_for(case: unittest.TestCase, role: str) -> str:
    temporary = tempfile.TemporaryDirectory()
    case.addCleanup(temporary.cleanup)
    planning = Path(temporary.name) / ".lbwc-planning"
    planning.mkdir()
    (planning / ".agent-manifest.json").write_text(json.dumps({"agents": {"worker": {"role": role}}}))
    return temporary.name


class PretoolInputContractTest(unittest.TestCase):
    def test_malformed_events_fail_open_with_a_diagnostic(self) -> None:
        rows = (
            "{not json",
            json.dumps({"tool_name": "Read"}),
            json.dumps({"tool_name": "", "tool_input": {}}),
            json.dumps({"tool_name": 1, "tool_input": {}}),
            json.dumps({"tool_input": {}}),
            "[]",
            json.dumps({"tool_name": "Write", "tool_input": []}),
        )
        for filename, event in product(HOOK_FILES, rows):
            with self.subTest(hook=filename, event=event):
                result = run_hook(filename, event)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("permissionDecision", result.stdout)
                self.assertEqual(result.stderr.strip(), skill_gate.MALFORMED_PRETOOL_INPUT)

    def test_non_applicable_events_remain_allowed(self) -> None:
        rows = (
            {"tool_name": "Read", "tool_input": {}},
            {"agent_id": "unregistered", "cwd": "/", "tool_name": "Write", "tool_input": {"file_path": "/repo/app.py"}},
        )
        for filename, event in product(HOOK_FILES, rows):
            with self.subTest(hook=filename, event=event):
                result = run_hook(filename, json.dumps(event))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")


class PolicyDenyStillDeniesTest(unittest.TestCase):
    def test_role_and_target_determine_the_hook_permission_decision(self) -> None:
        rows = (
            ("test_scope_guard.py", "python-engineer", "worker", {"file_path": "/repo/tests/test_feature.py", "content": "x"}, "deny", ""),
            ("test_scope_guard.py", "python-engineer", "worker", {}, None, ""),
            ("test_scope_guard.py", "python-engineer", "worker", {"file_path": "/repo/app.py"}, None, ""),
            ("test_scope_guard.py", "python-engineer", "", {"file_path": "/repo/tests/test_feature.py"}, None, ""),
            ("test_scope_guard.py", "test-dev", "worker", {"file_path": "/repo/tests/test_feature.py"}, None, ""),
            ("skill_gate.py", "lead", "worker", {"file_path": "/repo/PLAN.md"}, "deny", ""),
            ("user_question_guard.py", "", "", {"file_path": "src/app.py", "content": "x"}, "deny", "pretool"),
            ("user_question_guard.py", "", "", {}, "block", "stop"),
        )
        for filename, role, identifier, tool_input, decision, mode in rows:
            with self.subTest(hook=filename, role=role, identifier=identifier, target=tool_input):
                project = project_for(self, role)
                event = {"session_id": project, "agent_id": identifier, "cwd": project, "tool_name": "Write", "tool_input": tool_input}
                result = run_hook(filename, json.dumps(event), mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(result.stdout or '{}')
                output = payload.get("hookSpecificOutput", {})
                self.assertEqual(output.get("permissionDecision", payload.get("decision")), decision)
                self.assertEqual(output.get("hookEventName"), {"deny": "PreToolUse", "block": None, None: None}[decision])


if __name__ == "__main__":
    unittest.main()
