import json
import tempfile
import unittest
from pathlib import Path

from hooks import user_question_guard
from hooks.decision_records import record_digest


def seed_awaiting_freeform(planning_dir: Path, record: dict[str, object]) -> None:
    directory = planning_dir / ".runtime" / "decisions"
    session_id = str(record["session_id"])
    transition_id = str(record["transition_id"])
    record["status"] = "awaiting_freeform"
    record["record_digest"] = record_digest(record)
    authority = {key: record[key] for key in ("record_digest", "session_id", "transition_id")}
    (directory / f"{session_id}.json").write_text(json.dumps(record), encoding="utf-8")
    authority_path = directory / ".hook-transitions" / session_id / f"{transition_id}.json"
    authority_path.write_text(json.dumps(authority), encoding="utf-8")


class NativeQuestionContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        (self.root / ".meridian").mkdir()
        self.session_id = "native-question-session"

    def hook(self, event: dict[str, object], event_name: str) -> str | None:
        return user_question_guard.verdict(json.dumps(event), event_name)

    def question_event(self) -> dict[str, object]:
        return {
            "session_id": self.session_id,
            "cwd": str(self.root),
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    {
                        "header": "Review pace",
                        "question": "Which review pace should this project use?",
                        "options": [
                            {
                                "label": "Fast",
                                "description": "Finish the review sooner.",
                            },
                            {
                                "label": "Careful",
                                "description": "Check each change in detail.",
                            },
                        ],
                        "multiSelect": False,
                    }
                ]
            },
        }

    def test_pretool_validation_does_not_persist_a_record_for_an_invalid_question(
        self,
    ) -> None:
        event = self.question_event()
        event["tool_input"] = {
            "questions": [
                {
                    "header": "Review pace",
                    "question": "Which review pace should this project use?",
                    "options": [
                        {"label": "Fast", "description": "Finish the review sooner."},
                    ],
                    "multiSelect": False,
                }
            ]
        }
        self.assertIn("two to four choices", self.hook(event, "pretool") or "")
        store = user_question_guard.DecisionStore(self.root / ".meridian")
        self.assertEqual(store.state(self.session_id), "none")

    def test_native_other_does_not_require_a_duplicate_visible_option(self) -> None:
        self.assertIsNone(self.hook(self.question_event(), "pretool"))
        response = self.question_event()
        response["tool_input"] = {
            "answers": {
                "Which review pace should this project use?": "Use a calm but complete review."
            }
        }

        self.assertIsNone(self.hook(response, "posttool"))
        store = user_question_guard.DecisionStore(self.root / ".meridian")
        record = store.record(self.session_id)
        self.assertEqual(record["status"], "resolved")
        self.assertEqual(record["response"], {"kind": "freeform", "received": True})
        self.assertNotIn("Use a calm", json.dumps(record))

    def test_prompt_hook_drains_a_pre_upgrade_awaiting_freeform_record(self) -> None:
        planning_dir = self.root / ".meridian"
        store = user_question_guard.DecisionStore(planning_dir)
        self.assertIsNone(self.hook(self.question_event(), "pretool"))
        record = store.record(self.session_id)
        fingerprint = record["state_fingerprint"]
        seed_awaiting_freeform(planning_dir, record)
        self.assertEqual(store.state(self.session_id), "awaiting_freeform")

        prompt_event: dict[str, object] = {
            "session_id": self.session_id,
            "cwd": str(self.root),
            "prompt": "Use a calm but complete review.",
        }
        self.assertIsNone(self.hook(prompt_event, "prompt"))

        drained = store.record(self.session_id)
        self.assertEqual(drained["status"], "resolved")
        self.assertEqual(drained["response"], {"kind": "freeform", "received": True})
        self.assertEqual(drained["state_fingerprint"], fingerprint)


if __name__ == "__main__":
    unittest.main()
