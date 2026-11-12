import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType


def load_guard() -> ModuleType:
    sys.path.insert(0, str(Path(__file__).parent))
    import message_scope_guard
    return message_scope_guard


GUARD = load_guard()


class MessageScopeGuardTest(unittest.TestCase):
    def prepare_project(self) -> None:
        self.guard = GUARD
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.planning = self.root / ".meridian"
        self.planning.mkdir()

    def test_reporting_permission_follows_role_and_communication_policy(self) -> None:
        self.prepare_project()
        rows = (
            ({"role": "qa", "pair_id": None}, "agent-qa-1", "main", None),
            ({"role": "python-engineer", "pair_id": "p1"}, "agent-eng-1", "main", self.guard.blocked()),
            ({"role": "python-engineer", "pair_id": "p1", "runtime_kind": "native-team", "communication_policy": "native-team"}, "agent-eng-1", "main", None),
            ({"role": "python-engineer", "runtime_kind": "native-team", "communication_policy": "native-team"}, "agent-eng-1", "agent-critic-1", None),
            ({"role": "test-dev", "pair_id": "p1", "runtime_kind": "legacy-subagent", "communication_policy": "critic-relay"}, "agent-test-1", "main", None),
            ({"role": "python-engineer", "pair_id": "p1"}, "", "main", None),
            ({"role": "python-engineer", "cwd": "/"}, "unregistered", "main", None),
        )
        for entry, identifier, recipient, expected_reason in rows:
            with self.subTest(entry=entry, identifier=identifier, recipient=recipient):
                agents = {identifier: entry, "agent-critic-1": {"role": "python-critic", "pair_id": "p1"}}
                (self.planning / ".agent-manifest.json").write_text(json.dumps({"agents": agents}))
                event = json.dumps({"agent_id": identifier, "cwd": entry.get("cwd", str(self.root)), "tool_name": "SendMessage", "tool_input": {"to": recipient}})
                reason = self.guard.verdict(event)
                self.assertEqual(reason, expected_reason)

    def test_reporting_denial_reaches_the_hook_protocol(self) -> None:
        self.prepare_project()
        rows = (("python-engineer", "deny"), ("python-critic", None))
        for role, decision in rows:
            with self.subTest(role=role):
                agents = {"worker": {"role": role, "pair_id": "p1"}}
                (self.planning / ".agent-manifest.json").write_text(json.dumps({"agents": agents}))
                event = {"agent_id": "worker", "cwd": str(self.root), "tool_name": "SendMessage", "tool_input": {"to": "main"}}
                result = subprocess.run([sys.executable, str(Path(__file__).with_name("message_scope_guard.py"))], input=json.dumps(event), capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                output = json.loads(result.stdout or '{}').get("hookSpecificOutput", {})
                self.assertEqual(output.get("permissionDecision"), decision)


if __name__ == "__main__":
    unittest.main()
