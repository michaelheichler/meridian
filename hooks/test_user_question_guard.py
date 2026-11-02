import hashlib
import json
import os
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable

from hooks import decision_common, user_question_guard
from hooks.question_validation import validate_question

PROJECT_ROOT = Path(__file__).resolve().parent.parent


def rejected_reason(operation: Callable[[], object]) -> str:
    try:
        operation()
    except user_question_guard.DecisionStateError as error:
        return str(error)
    raise AssertionError("The fixture operation must reject its input.")


def question_event(session_id: str, cwd: Path) -> dict[str, Any]:
    return {
        "session_id": session_id, "cwd": str(cwd), "tool_name": "AskUserQuestion",
        "tool_input": {"questions": [{
            "header": "Review pace", "question": "Which review pace should this project use?",
            "options": [
                {"label": "Fast", "description": "Finish the review sooner."},
                {"label": "Careful", "description": "Check each change in detail."},
            ],
        }]},
    }


class QuestionFixture(unittest.TestCase):
    def prepare_project(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.planning_dir = self.root / ".lbwc-planning"
        self.planning_dir.mkdir()
        self.session_id = "session-1"

    def hook(self, event: Any, event_name: str) -> str | None:
        return user_question_guard.verdict(json.dumps(event), event_name)

    def store(self) -> user_question_guard.DecisionStore:
        return user_question_guard.DecisionStore(self.planning_dir)

    def event(self, tool: str, tool_input: dict) -> dict:
        return {"session_id": self.session_id, "cwd": str(self.root), "tool_name": tool, "tool_input": tool_input}

    def open_question(self) -> None:
        self.assertIsNone(self.hook(question_event(self.session_id, self.root), "pretool"))

    def answer(self, text: Any) -> dict:
        return self.event("AskUserQuestion", {"answers": {"Which review pace should this project use?": text}})

    def prepare_registration_case(self, stage: str) -> None:
        self.prepare_project()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        if stage != "none":
            self.open_question()
        if stage == "cancelled":
            self.hook(self.event("", {}), "stop")
        (self.planning_dir / ".context-usage").write_text("session usage")

    def registration_event(self, event_name: str) -> dict:
        events = {
            "PreToolUse": question_event(self.session_id, self.root),
            "PostToolUse": self.answer("Careful"),
            "UserPromptSubmit": {"session_id": self.session_id, "cwd": str(self.root), "prompt": "Continue from a new instruction."},
            "Stop": {"session_id": self.session_id, "cwd": str(self.root)},
        }
        return events[event_name]

    def run_registered_hooks(self, event_name: str, event: dict) -> list:
        config = json.loads((PROJECT_ROOT / "hooks" / "hooks.json").read_text())
        commands = [
            hook["command"]
            for entry in config["hooks"].get(event_name, [])
            if re.fullmatch(entry.get("matcher", ".*"), event.get("tool_name", ""))
            for hook in entry["hooks"]
        ]
        arguments = [shlex.split(command.replace("${CLAUDE_PLUGIN_ROOT}", str(PROJECT_ROOT))) for command in commands]
        guard_path = str(Path(user_question_guard.__file__).resolve())
        selected = [command for command in arguments if event_name == "Stop" or guard_path in command]
        environment = {**os.environ, "CLAUDE_PLUGIN_ROOT": str(PROJECT_ROOT), "LBWC_PLANNING_DIR": str(self.planning_dir), "CDPATH": ""}
        return [subprocess.run(command, input=json.dumps(event) + "\n", cwd=self.root,
                               env=environment, capture_output=True, text=True, check=False)
                for command in selected]


class QuestionLifecycleTest(QuestionFixture):
    def test_main_question_creates_pending_record_and_blocks_mutation(self) -> None:
        self.prepare_project()
        self.open_question()
        saved = self.store().record(self.session_id)
        self.assertEqual(saved["status"], "pending")
        self.assertEqual(saved["command"], "AskUserQuestion")
        self.assertEqual(self.hook(self.event("Write", {"file_path": "src/app.py", "content": "x"}), "pretool"), user_question_guard.PENDING_ORCHESTRATION_REASON)
        self.assertIsNone(self.hook(self.event("Read", {"file_path": "src/app.py"}), "pretool"))

    def test_bounded_answer_resolves_the_pending_record(self) -> None:
        self.prepare_project()
        self.open_question()
        self.assertIsNone(self.hook(self.answer("Careful"), "posttool"))
        saved = self.store().record(self.session_id)
        self.assertEqual(saved["status"], "resolved")
        self.assertEqual(saved["response"], "Careful")

    def test_freeform_answers_resolve_without_storing_private_text(self) -> None:
        rows = (("Use a calm but complete review.", "Use a calm"), ("Other", "Other"))
        for text, private_fragment in rows:
            with self.subTest(text=text):
                self.prepare_project()
                self.open_question()
                self.assertIsNone(self.hook(self.answer(text), "posttool"))
                saved = self.store().record(self.session_id)
                self.assertEqual(saved["status"], "resolved")
                self.assertEqual(saved["response"], {"kind": "freeform", "received": True})
                self.assertNotIn(private_fragment, json.dumps(saved))

    def test_pending_decision_blocks_sed_in_place_bash(self) -> None:
        self.prepare_project()
        self.open_question()
        event = self.event("Bash", {"command": "sed -i '' 's/old/new/' config.json"})
        self.assertEqual(self.hook(event, "pretool"), user_question_guard.PENDING_ORCHESTRATION_REASON)

    def test_stale_state_blocks_answer_and_stop(self) -> None:
        self.prepare_project()
        config = self.planning_dir / "config.json"
        config.write_text(json.dumps({"review": "careful"}))
        self.open_question()
        config.write_text(json.dumps({"review": "fast"}))
        self.assertIsNone(self.hook(self.answer("Careful"), "posttool"))
        self.assertEqual(self.store().record(self.session_id)["status"], "cancelled")
        self.assertIsNone(self.hook(self.event("", {}), "stop"))

    def test_stale_state_blocks_freeform_answer(self) -> None:
        self.prepare_project()
        routing = self.planning_dir / "routing.json"
        routing.write_text(json.dumps({"profile": "balanced"}))
        self.open_question()
        routing.write_text(json.dumps({"profile": "turbo"}))
        self.assertIsNone(self.hook(self.answer("Use a calm but complete review."), "posttool"))
        self.assertEqual(self.store().record(self.session_id)["status"], "cancelled")

    def test_changed_state_replaces_a_stale_pending_question(self) -> None:
        self.prepare_project()
        self.open_question()
        (self.planning_dir / "config.json").write_text(json.dumps({"review": "changed"}))
        self.assertIsNone(self.hook(question_event(self.session_id, self.root), "pretool"))

    def test_unchanged_state_cannot_replace_a_pending_question(self) -> None:
        self.prepare_project()
        self.open_question()
        event = question_event(self.session_id, self.root)
        expected_reason = rejected_reason(lambda: self.store().open(self.session_id, validate_question(event["tool_input"])))
        self.assertEqual(self.hook(event, "pretool"), expected_reason)

    def test_registered_hooks_enforce_the_decision_lifecycle(self) -> None:
        rows = (
            ("PreToolUse", "none", "AskUserQuestion", "pending", None, True),
            ("PostToolUse", "pending", "AskUserQuestion", "resolved", None, True),
            ("UserPromptSubmit", "cancelled", "", "resolved", None, True),
            ("Stop", "pending", "", "cancelled", None, False),
            ("PreToolUse", "pending", "Agent", "pending", "deny", True),
            ("PreToolUse", "pending", "Skill", "pending", "deny", True),
            ("PreToolUse", "pending", "SendMessage", "pending", "deny", True),
        )
        for event_name, stage, tool, status, decision, usage_exists in rows:
            with self.subTest(event=event_name, stage=stage, tool=tool):
                self.prepare_registration_case(stage)
                event = {**self.registration_event(event_name), "tool_name": tool}
                results = self.run_registered_hooks(event_name, event)
                self.assertTrue(results)
                self.assertEqual([result.returncode for result in results], [0] * len(results))
                decisions = [json.loads(result.stdout or '{}').get("hookSpecificOutput", {}).get("permissionDecision") for result in results]
                self.assertIn(decision, decisions)
                self.assertEqual(self.store().record(self.session_id)["status"], status)
                self.assertEqual((self.planning_dir / ".context-usage").exists(), usage_exists)

    def test_cancelled_question_resumes_normally(self) -> None:
        self.prepare_project()
        self.open_question()
        cancelled = self.event("AskUserQuestion", {})
        cancelled["is_error"] = True
        self.assertIsNone(self.hook(cancelled, "posttool"))
        self.assertEqual(self.store().record(self.session_id)["status"], "cancelled")
        agent = self.event("Agent", {"subagent_type": "qa"})
        self.assertIsNone(self.hook(agent, "pretool"))
        self.assertIsNone(self.hook(self.event("Skill", {"skill": "qa"}), "pretool"))
        self.assertIsNone(self.hook(self.event("", {}), "stop"))
        self.assertIsNone(self.hook(agent, "pretool"))

    def test_missing_answer_cancels_and_resumes_normally(self) -> None:
        rows = (({}, False), ({"answers": {"Which review pace should this project use?": 7}}, False),
                ({"answers": {"Which review pace should this project use?": "Careful"}}, True))
        for tool_input, is_error in rows:
            with self.subTest(tool_input=tool_input, is_error=is_error):
                self.prepare_project()
                self.open_question()
                event = self.event("AskUserQuestion", tool_input)
                event["is_error"] = is_error
                self.assertIsNone(self.hook(event, "posttool"))
                self.assertEqual(self.store().record(self.session_id)["status"], "cancelled")
                self.assertIsNone(self.hook(self.event("Write", {"file_path": "src/app.py", "content": "x"}), "pretool"))
                self.assertIsNone(self.hook(self.event("Read", {"file_path": "src/app.py"}), "pretool"))
                self.assertIsNone(self.hook(question_event(self.session_id, self.root), "pretool"))

    def test_new_prompt_acknowledges_cancelled_decision(self) -> None:
        self.prepare_project()
        self.open_question()
        self.assertIsNone(self.hook(self.event("", {}), "stop"))
        self.assertEqual(self.store().record(self.session_id)["status"], "cancelled")
        prompt = {"session_id": self.session_id, "cwd": str(self.root), "prompt": "Continue from a new instruction."}
        self.assertIsNone(self.hook(prompt, "prompt"))
        self.assertEqual(self.store().record(self.session_id)["status"], "resolved")
        self.assertIsNone(self.hook(self.event("Agent", {"subagent_type": "qa"}), "pretool"))


class QuestionValidationTest(QuestionFixture):
    def test_generated_agent_cannot_present_a_user_question(self) -> None:
        self.prepare_project()
        event = question_event(self.session_id, self.root)
        event["agent_id"] = "lbwc-worker"
        missing_session = {key: value for key, value in event.items() if key not in {"agent_id", "session_id"}}
        other_reasons = (None, self.hook(missing_session, "pretool"), user_question_guard.RESERVED_RUNTIME,
                         user_question_guard.PENDING_ORCHESTRATION_REASON, decision_common.INVALID_RECORD,
                         decision_common.INVALID_STATE, decision_common.INTEGRITY_FAILED, user_question_guard.MALFORMED_INPUT)
        self.assertNotIn(self.hook(event, "pretool"), other_reasons)
        self.assertEqual(self.store().state(self.session_id), "none")

    def test_technical_questions_and_options_do_not_create_a_record(self) -> None:
        rows = (
            {"question": "Which JSON schema should we use?", "options": [
                {"label": "One", "description": "Choose the first option."},
                {"label": "Two", "description": "Choose the second option."}]},
            {"question": "Which review pace should this project use?", "options": [
                {"label": "API choice", "description": "Choose this review pace."},
                {"label": "Careful", "description": "Change the JSON schema safely."}]},
        )
        for question in rows:
            with self.subTest(question=question):
                self.prepare_project()
                event = question_event(self.session_id, self.root)
                event["tool_input"] = {"questions": [question]}
                expected_reason = rejected_reason(lambda: validate_question(event["tool_input"]))
                self.assertEqual(self.hook(event, "pretool"), expected_reason)
                self.assertEqual(self.store().state(self.session_id), "none")

    def test_state_lookup_and_inapplicable_events_do_not_create_runtime_state(self) -> None:
        self.prepare_project()
        rows = (
            ("pretool", {"tool_name": "Read", "tool_input": {}}),
            ("pretool", {"tool_name": "Write", "tool_input": {}, "cwd": "/"}),
            ("pretool", {"tool_name": "Read", "tool_input": {}, "cwd": ""}),
            ("pretool", {"tool_name": "Read", "tool_input": {}, "cwd": 7}),
            ("pretool", {"tool_name": "Read", "tool_input": {}, "cwd": str(self.root)}),
            ("posttool", {"tool_name": "Read", "cwd": str(self.root)}),
            ("prompt", {"cwd": "/", "prompt": "Continue"}),
            ("prompt", {"cwd": str(self.root), "prompt": None}),
            ("prompt", {"cwd": str(self.root), "prompt": "  "}),
            ("stop", {"cwd": "/"}),
        )
        for mode, event in rows:
            with self.subTest(mode=mode, event=event):
                self.assertIsNone(self.hook(event, mode))
                self.assertEqual(self.store().state(self.session_id), "none")
                self.assertFalse((self.planning_dir / ".runtime").exists())

    def test_tampered_record_blocks_stop(self) -> None:
        self.prepare_project()
        self.open_question()
        path = self.planning_dir / ".runtime" / "decisions" / f"{self.session_id}.json"
        path.write_text(path.read_text().replace("AskUserQuestion", "AskUserQuestionX"))
        self.assertIn(decision_common.INTEGRITY_FAILED, self.hook(self.event("", {}), "stop") or "")

    def test_recomputed_record_checksum_without_hook_transition_is_invalid(self) -> None:
        self.prepare_project()
        self.open_question()
        path = self.planning_dir / ".runtime" / "decisions" / f"{self.session_id}.json"
        record = json.loads(path.read_text())
        record["command"] = "forged"
        unsigned = {key: value for key, value in record.items() if key != "record_digest"}
        encoded = json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode("utf-8")
        record["record_digest"] = hashlib.sha256(encoded).hexdigest()
        path.write_text(json.dumps(record, separators=(",", ":")))
        with self.assertRaises(user_question_guard.DecisionStateError) as failure:
            self.store().state(self.session_id)
        self.assertEqual(str(failure.exception), decision_common.INTEGRITY_FAILED)

    def test_missing_session_blocks_mutation_stop_and_questions(self) -> None:
        self.prepare_project()
        question = question_event(self.session_id, self.root)
        del question["session_id"]
        mutation = {"cwd": str(self.root), "tool_name": "Write", "tool_input": {"file_path": "src/app.py", "content": "x"}}
        mutation_reason = self.hook(mutation, "pretool")
        stop_reason = self.hook({"cwd": str(self.root)}, "stop")
        generated_question = {**question, "session_id": self.session_id, "agent_id": "lbwc-worker"}
        other_reasons = (None, user_question_guard.RESERVED_RUNTIME, user_question_guard.PENDING_ORCHESTRATION_REASON,
                         decision_common.INVALID_RECORD, decision_common.INVALID_STATE, decision_common.INTEGRITY_FAILED,
                         user_question_guard.MALFORMED_INPUT, self.hook(generated_question, "pretool"))
        self.assertNotIn(mutation_reason, other_reasons)
        self.assertNotIn(stop_reason, (*other_reasons, mutation_reason))
        rows = (("pretool", mutation, mutation_reason), ("stop", {"cwd": str(self.root)}, stop_reason),
                ("pretool", question, mutation_reason))
        for mode, event, expected_reason in rows:
            with self.subTest(mode=mode, event=event):
                self.assertEqual(self.hook(event, mode), expected_reason)
                self.assertFalse((self.planning_dir / ".runtime").exists())

    def test_symlinked_planning_state_blocks_mutation_and_stop(self) -> None:
        self.prepare_project()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        linked_root = Path(temporary.name)
        (linked_root / ".lbwc-planning").symlink_to(self.planning_dir, target_is_directory=True)
        mutation = {"session_id": self.session_id, "cwd": str(linked_root), "tool_name": "Write", "tool_input": {"file_path": "src/app.py", "content": "x"}}
        self.assertEqual(self.hook(mutation, "pretool"), decision_common.INVALID_STATE)
        self.assertIn(decision_common.INVALID_STATE, self.hook({"session_id": self.session_id, "cwd": str(linked_root)}, "stop") or "")

    def test_visible_other_option_is_rejected(self) -> None:
        self.prepare_project()
        event = question_event(self.session_id, self.root)
        event["tool_input"] = {"questions": [{
            "question": "Which review pace should this project use?",
            "options": [{"label": "Fast", "description": "Finish the review sooner."},
                        {"label": "Other", "description": "Something else entirely."}],
        }]}
        expected_reason = rejected_reason(lambda: validate_question(event["tool_input"]))
        self.assertEqual(self.hook(event, "pretool"), expected_reason)

    def test_runtime_paths_are_reserved_without_a_pending_record(self) -> None:
        self.prepare_project()
        rows = (
            (self.event("Bash", {"command": "mkdir -p .lbwc-planning/.runtime/decisions"}), user_question_guard.RESERVED_RUNTIME),
            (self.event("Bash", {"command": "bash scripts/pending-decision.sh create .lbwc-planning session-1"}), user_question_guard.RESERVED_RUNTIME),
            (self.event("Write", {"file_path": ".lbwc-planning/.runtime/decisions/forged.json", "content": "{}"}), user_question_guard.RESERVED_RUNTIME),
        )
        for event, expected_reason in rows:
            with self.subTest(event=event):
                self.assertEqual(self.hook(event, "pretool"), expected_reason)

    def test_symlink_and_traversal_aliases_to_protected_paths_are_reserved(self) -> None:
        self.prepare_project()
        script_alias = self.root / "decision-alias"
        script_alias.symlink_to(PROJECT_ROOT / "scripts" / "pending-decision.sh")
        runtime = self.planning_dir / ".runtime"
        runtime.mkdir()
        runtime_alias = self.root / "runtime-alias"
        runtime_alias.symlink_to(runtime, target_is_directory=True)
        rows = (
            (f"bash {script_alias} create .lbwc-planning session-1", user_question_guard.RESERVED_RUNTIME),
            (f"mkdir -p {runtime_alias}/decisions", user_question_guard.RESERVED_RUNTIME),
            ("mkdir -p .lbwc-planning/cache/../.runtime/decisions", user_question_guard.RESERVED_RUNTIME),
        )
        for command, expected_reason in rows:
            with self.subTest(command=command):
                self.assertEqual(self.hook(self.event("Bash", {"command": command}), "pretool"), expected_reason)

    def test_indirect_runtime_tampering_fails_closed_for_later_tools(self) -> None:
        self.prepare_project()
        decisions = self.planning_dir / ".runtime" / "decisions"
        decisions.mkdir(parents=True)
        (decisions / f"{self.session_id}.json").write_text("{}")
        self.assertEqual(self.hook(self.event("Write", {"file_path": "src/app.py", "content": "x"}), "pretool"), decision_common.INVALID_RECORD)


if __name__ == "__main__":
    unittest.main()
