import shlex
import subprocess
import sys
import unittest
from pathlib import Path

from hooks.commit_command import commit_segment

SCRIPT = Path(__file__).resolve().parent / "commit_command.py"


def segment_words(command: str) -> list[str] | None:
    segment = commit_segment(command)
    return None if segment is None else shlex.split(segment)


def run_cli(command: str) -> tuple[int, str, str]:
    completed = subprocess.run(
        [sys.executable, "-B", str(SCRIPT)], input=command, text=True,
        capture_output=True, timeout=10, check=False,
    )
    return completed.returncode, completed.stdout, completed.stderr


class CommitSegmentTest(unittest.TestCase):
    def test_text_that_only_mentions_git_commit_has_no_commit_segment(self) -> None:
        commands = [
            "echo git commit -m bad",
            "python3 probe.py 'f() { shift; \"$@\"; }; f x git commit -m x'",
            "python3 runner.py 'git commit -m bad'",
            "printf %s \"sh -c 'git commit -m bad'\"",
            "git status",
        ]

        found = {command: segment_words(command) for command in commands}

        self.assertEqual(found, dict.fromkeys(commands))

    def test_commit_segment_is_found_behind_wrappers_git_options_and_separators(self) -> None:
        expected = {
            "env FOO=1 git commit -m x": ["env", "FOO=1", "git", "commit", "-m", "x"],
            "git -C /path commit -m x": ["git", "-C", "/path", "commit", "-m", "x"],
            "git -c k=v commit -m x": ["git", "-c", "k=v", "commit", "-m", "x"],
            "git status && git commit -m x": ["git", "commit", "-m", "x"],
            "true; git commit -m x": ["git", "commit", "-m", "x"],
            "timeout 5 git commit -m x": ["timeout", "5", "git", "commit", "-m", "x"],
            "sudo -u me git commit -m x": ["sudo", "-u", "me", "git", "commit", "-m", "x"],
            'echo -m bad && git commit -m "feat(a): s"': ["git", "commit", "-m", "feat(a): s"],
            'git commit -m "fix(a): don\'t drop x"': ["git", "commit", "-m", "fix(a): don't drop x"],
        }

        found = {command: segment_words(command) for command in expected}

        self.assertEqual(found, expected)


class CommitCommandCliTest(unittest.TestCase):
    def test_cli_prints_the_commit_segment_and_exits_zero(self) -> None:
        status, stdout, stderr = run_cli("git status && git commit -m x")

        self.assertEqual((status, shlex.split(stdout), stderr), (0, ["git", "commit", "-m", "x"], ""))

    def test_cli_prints_nothing_and_exits_one_without_a_commit(self) -> None:
        status, stdout, stderr = run_cli("echo git commit -m bad")

        self.assertEqual((status, stdout, stderr), (1, "", ""))


if __name__ == "__main__":
    unittest.main()
