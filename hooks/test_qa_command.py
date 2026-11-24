import json
import shlex
import subprocess
import sys
import unittest
from pathlib import Path

from hooks.guard_fixtures import (
    bash_reason,
    build_project,
    build_workspace,
    load_guard,
    question_event,
    run_mode,
    tool_event,
)


def qa_shell(*arguments: str) -> str:
    script = Path(__file__).resolve().parents[1] / "scripts" / "qa-phase.py"
    return shlex.join([sys.executable, "-I", "-B", str(script), *arguments])


def task_contract(operation: str, root: Path, *arguments: str) -> str:
    script = Path(__file__).resolve().parents[1] / "scripts" / "task-contract.sh"
    return subprocess.check_output(
        ["/bin/bash", str(script), operation, str(root), *arguments],
        cwd=root, text=True, timeout=10,
    ).strip()


def phase_worker_event(root: Path, prompt: str) -> dict:
    return tool_event("Agent", {"subagent_type": "meridian:phase-qa", "prompt": prompt}, root)


def hook_permission(stdout: str) -> str | None:
    response = json.loads(stdout or "{}")
    return response.get("hookSpecificOutput", {}).get("permissionDecision")


def phase_worker_bash(root: Path, command: str) -> subprocess.CompletedProcess[str]:
    script = Path(__file__).resolve().parents[1] / "scripts" / "bash-guard.sh"
    event = tool_event("Bash", {"command": command}, root)
    event.update(agent_id="ff8f4ebc-7711-4673-8055-4f3e998bc821", agent_type="meridian:phase-qa")
    return subprocess.run(
        ["/bin/bash", str(script)], input=json.dumps(event), text=True, cwd=root,
        capture_output=True, timeout=10, check=False,
    )


class QaCommandTest(unittest.TestCase):
    def test_literal_qa_route_can_pass_the_decision_guard(self) -> None:
        space = build_workspace(self)
        script = Path(__file__).resolve().parents[1] / "scripts" / "qa-phase.py"
        command = shlex.join([sys.executable, "-I", "-B", str(script), "inspect", "01"])
        self.assertIsNone(bash_reason(command, space.root))

    def test_qa_route_does_not_open_the_guard_to_other_commands(self) -> None:
        space = build_workspace(self)
        script = Path(__file__).resolve().parents[1] / "scripts" / "qa-phase.py"
        command = shlex.join([sys.executable, "-I", "-B", str(script), "inspect", "01"])
        for unsafe in (command + " && cat .meridian/.runtime/decisions/secret.txt",
                       command.replace("inspect 01", "inspect ../.runtime"),
                       command.replace("inspect 01", "inspect $(cat secret.txt)")):
            with self.subTest(unsafe=unsafe):
                self.assertIsNotNone(bash_reason(unsafe, space.root))

    def test_qa_worker_cannot_use_the_parent_start_operation(self) -> None:
        space = build_workspace(self)
        script = Path(__file__).resolve().parents[1] / "scripts" / "qa-phase.py"
        command = shlex.join([sys.executable, "-I", "-B", str(script), "start", "01", "quick", "claude"])
        payload = tool_event("Bash", {"command": command}, space.root)
        payload["agent_type"] = "meridian-qa"
        self.assertIsNotNone(load_guard().verdict(json.dumps(payload), "pretool"))

    def test_routing_accepts_unknown_and_recognized_ownership(self) -> None:
        space = build_workspace(self)
        ownership = [
            {"task_id": "01-01", "owners": []},
            {"task_id": "01-02", "owners": ["docs", "test-dev"]},
        ]
        command = qa_shell("route", "01", json.dumps(ownership))

        self.assertIsNone(bash_reason(command, space.root))

    def test_routing_requires_owners_to_be_an_array(self) -> None:
        space = build_workspace(self)
        ownership = [{"task_id": "01-01", "owners": "docs"}]
        command = qa_shell("route", "01", json.dumps(ownership))

        self.assertEqual(bash_reason(command, space.root), load_guard().RESERVED_RUNTIME)

    def test_routing_rejects_shell_syntax_in_owner_names(self) -> None:
        space = build_workspace(self)
        ownership = [{"task_id": "01-01", "owners": ["$(printf docs)"]}]
        command = qa_shell("route", "01", json.dumps(ownership))

        self.assertEqual(bash_reason(command, space.root), load_guard().RESERVED_RUNTIME)

    def test_routing_rejects_a_shell_command_after_the_ownership_argument(self) -> None:
        space = build_workspace(self)
        ownership = [{"task_id": "01-01", "owners": ["docs"]}]
        command = qa_shell("route", "01", json.dumps(ownership)) + " && printf injected"

        self.assertEqual(bash_reason(command, space.root), load_guard().RESERVED_RUNTIME)

    def test_publish_accepts_literal_apostrophe_encodings_and_rejects_shell_chains(self) -> None:
        space = build_workspace(self)
        arguments = ("publish", "01", "cmd-qa-qa-01-deadbeefcafe-phase")
        verdict = json.dumps({"phase": "01", "evidence": "The cache's proof passed."})
        standard = qa_shell(*arguments, verdict)
        escaped_apostrophe = r"'\''"
        posix = qa_shell(*arguments) + " '" + escaped_apostrophe.join(verdict.split("'")) + "'"
        reserved = load_guard().RESERVED_RUNTIME

        self.assertIsNone(bash_reason(standard, space.root))
        self.assertIsNone(bash_reason(posix, space.root))
        self.assertEqual(bash_reason(standard + " && printf injected", space.root), reserved)
        self.assertEqual(bash_reason(posix + " && printf injected", space.root), reserved)

    def test_qa_start_still_waits_for_an_open_user_decision(self) -> None:
        space = build_project(self)
        guard = load_guard()
        question = question_event(space.root, "sess-1")
        self.assertIsNone(guard.verdict(json.dumps(question), "pretool"))
        command = qa_shell("start", "01", "quick", "claude")

        self.assertEqual(bash_reason(command, space.root), guard.PENDING_ORCHESTRATION_REASON)

    def test_phase_worker_claims_a_dispatched_contract_once(self) -> None:
        space = build_project(self)
        contract_path = task_contract(
            "issue", space.root, "qa-01-deadbeefcafe", "--command", "qa", "--role", "qa",
            "--team", "solo", "--group", "phase", "--job", "Verify phase 01.",
        )
        contract_id = Path(contract_path).stem
        task_contract("state", space.root, contract_id, "dispatched")
        event = phase_worker_event(space.root, f"Verify phase 01.\nMeridian-Contract: {contract_id}")

        admitted = run_mode("pretool", event)
        state_after_admission = json.loads(task_contract("read", space.root, contract_id))["state"]
        replay = run_mode("pretool", event)

        self.assertEqual((admitted.returncode, admitted.stdout), (0, ""))
        self.assertEqual(state_after_admission, "running")
        self.assertEqual(replay.returncode, 0)
        self.assertEqual(hook_permission(replay.stdout), "deny")

    def test_phase_worker_spawn_requires_a_contract_in_the_prompt(self) -> None:
        space = build_project(self)

        denied = run_mode("pretool", phase_worker_event(space.root, "Verify phase 01."))

        self.assertEqual(denied.returncode, 0)
        self.assertEqual(hook_permission(denied.stdout), "deny")

    def test_namespaced_phase_worker_keeps_read_only_bash_with_an_opaque_id(self) -> None:
        space = build_project(self)

        proof = phase_worker_bash(space.root, "python3 -I -B verify_cache.py")
        mutation = phase_worker_bash(space.root, "touch should-not-exist")

        self.assertEqual((proof.returncode, proof.stdout, proof.stderr), (0, "", ""))
        self.assertEqual(mutation.returncode, 2)
        self.assertIn("read-only (filesystem mutation command)", mutation.stderr)
