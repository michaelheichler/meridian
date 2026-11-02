import json
import shutil
import signal
import time
import unittest
from pathlib import Path
from typing import Callable
from unittest import mock

from hooks import guard_paths
from hooks.guard_fixtures import (
    answer_event,
    bash_reason,
    build_project,
    build_workspace,
    question_event,
    run_entry,
    run_mode,
    tool_event,
)

MODES = ("pretool", "posttool", "prompt", "stop")
NUL_CWD = "a\u0000b"
TIMEOUT_REASON = "guard analysis timeout"
SHORT_DEADLINE = 0.2
SLOW_EXPANSION_SECONDS = 2


def slow_expansion(_pattern: str) -> list:
    time.sleep(SLOW_EXPANSION_SECONDS)
    return []


def snapshot(directory: Path) -> dict:
    return {
        str(path.relative_to(directory)): path.read_bytes()
        for path in sorted(directory.rglob("*"))
        if path.is_file()
    }


def decision_record(planning: Path, session: str) -> dict:
    return json.loads(run_entry(["decision-read", "get", str(planning), session]).stdout)


def failing_event(mode: str) -> dict:
    tool = "AskUserQuestion" if mode == "posttool" else "Bash"
    event = tool_event(tool, {"command": "true"}, Path("."))
    return {**event, "cwd": NUL_CWD, "prompt": "hi"}


class AnalysisDeadlineTest(unittest.TestCase):
    def slow_command_reason(self) -> str | None:
        space = build_workspace(self)
        with mock.patch.object(guard_paths, "ANALYSIS_SECONDS", SHORT_DEADLINE):
            with mock.patch.object(guard_paths, "expand_glob", slow_expansion):
                return bash_reason("cat x*", space.root)

    def install_marker_handler(self) -> Callable:
        def marker(_signum: int, _frame: object) -> None:
            return None

        previous = signal.signal(signal.SIGALRM, marker)
        self.addCleanup(signal.signal, signal.SIGALRM, previous)
        return marker

    def test_slow_analysis_is_denied_with_the_timeout_reason(self) -> None:
        self.assertEqual(self.slow_command_reason(), TIMEOUT_REASON)

    def test_previous_alarm_handler_is_restored_after_analysis(self) -> None:
        space = build_workspace(self)
        rows = (self.slow_command_reason, lambda: bash_reason("cat plain.txt", space.root))
        for analyse in rows:
            with self.subTest(analyse=analyse):
                marker = self.install_marker_handler()
                analyse()
                self.assertIs(signal.getsignal(signal.SIGALRM), marker)

    def test_no_alarm_stays_armed_after_a_normal_analysis(self) -> None:
        space = build_workspace(self)
        bash_reason("cat plain.txt", space.root)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0.0, 0.0))


class FailOpenTest(unittest.TestCase):
    def test_invalid_input_and_analysis_errors_fail_open_in_every_mode(self) -> None:
        rows = [(mode, payload) for mode in MODES for payload in ("{not json", "[]", json.dumps(failing_event(mode)))]
        for mode, payload in rows:
            with self.subTest(mode=mode, payload=payload):
                result = run_entry([mode], payload)
                self.assertEqual((result.returncode, result.stdout), (0, ""))
                self.assertTrue(result.stderr.strip())


class AnswerSessionTest(unittest.TestCase):
    def open_question(self, space, session: str) -> None:
        result = run_mode("pretool", question_event(space.root, session))
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_answer_from_the_same_session_resolves_the_decision(self) -> None:
        space = build_project(self)
        self.open_question(space, "sess-a")
        run_mode("posttool", answer_event(space.root, "sess-a", "Careful"))
        record = decision_record(space.planning, "sess-a")
        self.assertEqual((record["status"], record["response"]), ("resolved", "Careful"))

    def test_answer_from_another_session_leaves_the_decision_pending(self) -> None:
        space = build_project(self)
        self.open_question(space, "sess-a")
        before = snapshot(space.planning)
        result = run_mode("posttool", answer_event(space.root, "sess-b", "Careful"))
        self.assertEqual(result.stdout, "")
        self.assertEqual(snapshot(space.planning), before)

    def test_record_filed_under_a_different_session_denies_and_changes_nothing(self) -> None:
        space = build_project(self)
        self.open_question(space, "sess-a")
        self.open_question(space, "sess-b")
        shutil.copyfile(space.decisions / "sess-a.json", space.decisions / "sess-b.json")
        before = snapshot(space.planning)
        result = run_mode("posttool", answer_event(space.root, "sess-b", "Careful"))
        context = json.loads(result.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertTrue(context)
        self.assertEqual(snapshot(space.planning), before)


if __name__ == "__main__":
    unittest.main()
