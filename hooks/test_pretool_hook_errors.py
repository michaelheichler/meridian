"""Hooks fail open on unparseable events, so a hook bug never blocks a tool call, while policy denies stay."""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest


def _hook_path(filename: str) -> str:
    return os.path.join(os.path.dirname(__file__), filename)


def _malformed_input_message() -> str:
    spec = importlib.util.spec_from_file_location("skill_gate_under_test", _hook_path("skill_gate.py"))
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.MALFORMED_PRETOOL_INPUT


def _run_hook(filename: str, stdin_text: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, _hook_path(filename)],
        input=stdin_text,
        capture_output=True,
        text=True,
        check=False,
    )


def _assert_allowed_with_parse_error(case: unittest.TestCase, result: subprocess.CompletedProcess[str]) -> None:
    case.assertEqual(result.returncode, 0, result.stderr)
    case.assertNotIn("permissionDecision", result.stdout)
    case.assertIn(_malformed_input_message(), result.stderr)


class _MalformedInputAllowedContract:
    hook_file: str

    def test_malformed_json_is_allowed_with_the_parse_error_on_stderr(self) -> None:
        _assert_allowed_with_parse_error(self, _run_hook(self.hook_file, "{not json"))

    def test_missing_tool_input_is_allowed_with_the_parse_error_on_stderr(self) -> None:
        event = json.dumps({"tool_name": "Read"})
        _assert_allowed_with_parse_error(self, _run_hook(self.hook_file, event))

    def test_empty_tool_name_is_allowed_with_the_parse_error_on_stderr(self) -> None:
        event = json.dumps({"tool_name": "", "tool_input": {}})
        _assert_allowed_with_parse_error(self, _run_hook(self.hook_file, event))

    def test_non_string_tool_name_is_allowed_with_the_parse_error_on_stderr(self) -> None:
        event = json.dumps({"tool_name": 1, "tool_input": {}})
        _assert_allowed_with_parse_error(self, _run_hook(self.hook_file, event))

    def test_absent_tool_name_is_allowed_with_the_parse_error_on_stderr(self) -> None:
        event = json.dumps({"tool_input": {}})
        _assert_allowed_with_parse_error(self, _run_hook(self.hook_file, event))

    def test_valid_non_applicable_event_remains_allowed(self) -> None:
        event = json.dumps({"tool_name": "Read", "tool_input": {}})
        result = _run_hook(self.hook_file, event)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")


class SkillGateMalformedInputTest(_MalformedInputAllowedContract, unittest.TestCase):
    hook_file = "skill_gate.py"


class MessageScopeGuardMalformedInputTest(_MalformedInputAllowedContract, unittest.TestCase):
    hook_file = "message_scope_guard.py"


class TestScopeGuardMalformedInputTest(_MalformedInputAllowedContract, unittest.TestCase):
    hook_file = "test_scope_guard.py"


class PolicyDenyStillDeniesTest(unittest.TestCase):
    def test_engineer_writing_into_test_directory_is_denied_end_to_end(self) -> None:
        project = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, project, ignore_errors=True)
        planning_dir = os.path.join(project, ".lbwc-planning")
        os.makedirs(planning_dir)
        with open(os.path.join(planning_dir, ".agent-manifest.json"), "w") as manifest_file:
            json.dump({"agents": {"agent-eng-1": {"role": "python-engineer"}}}, manifest_file)
        event = json.dumps({
            "agent_id": "agent-eng-1",
            "cwd": project,
            "tool_name": "Write",
            "tool_input": {"file_path": "/repo/tests/test_feature.py", "content": "x"},
        })

        result = _run_hook("test_scope_guard.py", event)

        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "PreToolUse")
        self.assertEqual(output["permissionDecision"], "deny")


if __name__ == "__main__":
    unittest.main()
