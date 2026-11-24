import shlex
import subprocess
import sys
import unittest
from pathlib import Path

from hooks.commit_command import commit_segment, nonconforming_subject

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


class NonconformingSubjectTest(unittest.TestCase):
    def test_nonconforming_subject_is_reported_wherever_the_commit_runs(self) -> None:
        expected = {
            'git commit --message="bad msg"': "bad msg",
            'git commit -m"bad msg"': "bad msg",
            'git commit -am "bad x"': "bad x",
            "echo x | xargs git commit -m bad": "bad",
            "/usr/bin/git commit -m bad": "bad",
            "{ git commit -m bad; }": "bad",
            "if true; then git commit -m bad; fi": "bad",
            "for f in a; do git commit -m bad; done": "bad",
            'bash -c "git commit -m bad"': "bad",
            "sh -c 'git commit -m bad'": "bad",
            "echo `git commit -m bad`": "bad",
            "git commit \\\n  -m bad": "bad",
            "env FOO=1 git commit -m x": "x",
            "git status && git commit -m x": "x",
        }

        found = {command: nonconforming_subject(command, "") for command in expected}

        self.assertEqual(found, expected)

    def test_conforming_or_absent_subject_is_not_reported(self) -> None:
        commands = [
            'git commit -m "feat(user\'s): add x"',
            'git commit -m "feat(a): x" && cat <<EOF\nrandom text\nEOF',
            'git commit -m "fix(a): don\'t drop x"',
            'echo -m bad && git commit -m "feat(a): s"',
            "echo git commit -m bad",
            "git commit --amend --no-edit",
        ]

        found = {command: nonconforming_subject(command, "") for command in commands}

        self.assertEqual(found, dict.fromkeys(commands))


class CommitCommandCliTest(unittest.TestCase):
    def test_cli_prints_the_nonconforming_subject_and_exits_zero(self) -> None:
        status, stdout, stderr = run_cli("git status && git commit -m x")

        self.assertEqual((status, stdout, stderr), (0, "x\n", ""))

    def test_cli_prints_nothing_and_exits_one_for_a_conforming_subject(self) -> None:
        status, stdout, stderr = run_cli('git commit -m "feat(a): s"')

        self.assertEqual((status, stdout, stderr), (1, "", ""))

    def test_cli_prints_nothing_and_exits_one_without_a_commit(self) -> None:
        status, stdout, stderr = run_cli("echo git commit -m bad")

        self.assertEqual((status, stdout, stderr), (1, "", ""))


if __name__ == "__main__":
    unittest.main()
