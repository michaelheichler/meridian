import json
import subprocess
import sys
import tempfile
import unittest
from itertools import product
from pathlib import Path

from hooks import skill_gate

HOOK_FILES = ("skill_gate.py", "message_scope_guard.py", "scope_guard.py")


def run_hook(filename: str, stdin_text: str, mode: str = "") -> subprocess.CompletedProcess[str]:
    arguments = [mode] if mode else []
    return subprocess.run(
        [sys.executable, str(Path(__file__).parent / filename), *arguments],
        input=stdin_text, capture_output=True, text=True, check=False,
    )


def project_for(case: unittest.TestCase, role: str) -> str:
    temporary = tempfile.TemporaryDirectory()
    case.addCleanup(temporary.cleanup)
    planning = Path(temporary.name) / ".meridian"
    planning.mkdir()
    (planning / ".agent-manifest.json").write_text(json.dumps({"agents": {"worker": {"role": role}}}))
    return temporary.name


def manifest(role: str) -> str:
    return json.dumps({"agents": {"worker": {"role": role, "pair_id": "pair-a"}}})


GATE_ROWS = (
    ("skill_gate.py", "lead", "Write", {"file_path": "/repo/PLAN.md"}),
    ("scope_guard.py", "python-engineer", "Write", {"file_path": "/repo/tests/test_feature.py"}),
    ("message_scope_guard.py", "python-engineer", "SendMessage", {"to": "main", "message": "progress"}),
)
INVALID_DOCUMENTS = ("{", "[]", "null", '{"agents":[]}', '{"agents":null}', "{}", '{"agents":{"worker":null}}',
                     '{"agents":{"worker":[]}}', '{"agents":{"worker":{"role":[]}}}')
TEST_FILE = {"file_path": "/repo/tests/test_feature.py"}
MANIFEST_CASES = [
    (filename, tool, tool_input, current, manifest(role), "deny", "")
    for filename, role, tool, tool_input in GATE_ROWS for current in (None, "", '{"agents":{}}')
] + [
    (filename, tool, tool_input, manifest(role), None, "deny", "") for filename, role, tool, tool_input in GATE_ROWS
] + [
    (filename, tool, tool_input, current, legacy, "deny", "manifest")
    for filename, role, tool, tool_input in GATE_ROWS for invalid in INVALID_DOCUMENTS
    for current, legacy in ((invalid, None), (None, invalid), (invalid, manifest(role)))
] + [
    ("scope_guard.py", "Write", TEST_FILE, manifest("test-dev"), manifest("python-engineer"), None, ""),
    ("scope_guard.py", "Write", TEST_FILE, manifest("python-engineer"), manifest("test-dev"), "deny", ""),
] + [
    ("scope_guard.py", "NotebookEdit", {"notebook_path": path, "new_source": "x"}, manifest(role), None, expected, "")
    for role, path, expected in (
        ("python-engineer", "/repo/tests/test_feature.ipynb", "deny"),
        ("python-engineer", "/repo/test/fixture.ipynb", "deny"),
        ("python-engineer", "/repo/src/feature.test.ipynb", "deny"),
        ("python-engineer", "/repo/notebooks/feature.ipynb", None),
        ("test-dev", "/repo/tests/test_feature.ipynb", None),
    )
]


def place_manifest(directory: Path, document: "str | None") -> None:
    if document is None:
        return
    directory.mkdir()
    if document:
        (directory / ".agent-manifest.json").write_text(document)


def gate_output(case: unittest.TestCase, row: list) -> dict:
    filename, tool, tool_input, current, legacy = row
    temporary = tempfile.TemporaryDirectory()
    case.addCleanup(temporary.cleanup)
    project = Path(temporary.name)
    place_manifest(project / ".meridian", current)
    place_manifest(project / ".lbwc-planning", legacy)
    (project / "nested").mkdir()
    event = {"session_id": str(project), "agent_id": "worker", "cwd": str(project / "nested"), "tool_name": tool, "tool_input": tool_input}
    result = run_hook(filename, json.dumps(event))
    case.assertEqual((result.returncode, result.stderr), (0, ""))
    return json.loads(result.stdout or "{}").get("hookSpecificOutput", {})


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
            ("scope_guard.py", "python-engineer", "worker", {"file_path": "/repo/tests/test_feature.py", "content": "x"}, "deny", ""),
            ("scope_guard.py", "python-engineer", "worker", {}, None, ""),
            ("scope_guard.py", "python-engineer", "worker", {"file_path": "/repo/app.py"}, None, ""),
            ("scope_guard.py", "python-engineer", "", {"file_path": "/repo/tests/test_feature.py"}, None, ""),
            ("scope_guard.py", "test-dev", "worker", {"file_path": "/repo/tests/test_feature.py"}, None, ""),
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
        for *event_row, expected, reason in MANIFEST_CASES:
            with self.subTest(event=event_row):
                output = gate_output(self, event_row)
                self.assertEqual(output.get("permissionDecision"), expected)
                self.assertIn(reason, output.get("permissionDecisionReason", "").lower())


if __name__ == "__main__":
    unittest.main()
