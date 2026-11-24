import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from hooks.commit_command import nonconforming_subject

SCRIPT = Path(__file__).resolve().parent / "commit_command.py"


def run_cli(command: str) -> tuple[int, str, str]:
    completed = subprocess.run(
        [sys.executable, "-B", str(SCRIPT)], input=command, text=True,
        capture_output=True, timeout=10, check=False,
    )
    return completed.returncode, completed.stdout, completed.stderr


def message_file_directory(test: unittest.TestCase, first_line: str) -> Path:
    directory = tempfile.TemporaryDirectory()
    test.addCleanup(directory.cleanup)
    root = Path(directory.name)
    (root / "message.txt").write_text(first_line + "\nfeat(a): body line\n")
    return root


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
            "git -C /path commit -m x": "x",
            "git -c k=v commit -m x": "x",
            "git status && git commit -m x": "x",
            "true; git commit -m x": "x",
            "timeout 5 git commit -m x": "x",
            "sudo -u me git commit -m x": "x",
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
            "python3 probe.py 'f() { shift; \"$@\"; }; f x git commit -m x'",
            "python3 runner.py 'git commit -m bad'",
            "printf %s \"sh -c 'git commit -m bad'\"",
            "git status",
            "git commit --amend --no-edit",
        ]

        found = {command: nonconforming_subject(command, "") for command in commands}

        self.assertEqual(found, dict.fromkeys(commands))

    def test_heredoc_bodies_hide_commit_text_but_not_the_commit_after_them(self) -> None:
        expected = {
            "cat <<EOF\ngit commit -m bad\nEOF": None,
            "cat > f <<'EOF'\ngit commit -m bad\nEOF": None,
            "cat > f <<'EOF'\ngit commit -m bad\nEOF\ngit commit -m worse": "worse",
            'git commit -m x <<< "y"': "x",
            'git commit -m "feat(a): x" <<< EOF\ngit commit -m bad': "bad",
        }

        found = {command: nonconforming_subject(command, "") for command in expected}

        self.assertEqual(found, expected)

    def test_every_commit_call_is_checked_and_option_values_are_skipped(self) -> None:
        expected = {
            'git commit -m "feat(a): x" && git commit -m "bad"': "bad",
            'git commit --trailer "-m x" -m "feat(a): x"': None,
            'git commit -unormal -m "feat(a): x"': None,
            "git commit -C HEAD -m bad": "bad",
        }

        found = {command: nonconforming_subject(command, "") for command in expected}

        self.assertEqual(found, expected)

    def test_runtime_placeholders_are_not_reported_as_subjects(self) -> None:
        commands = ['git commit -m "$MSG"', "xargs -I{} git commit -m {}"]

        found = {command: nonconforming_subject(command, "") for command in commands}

        self.assertEqual(found, dict.fromkeys(commands))

    def test_message_file_subject_is_read_relative_to_the_cwd(self) -> None:
        root = message_file_directory(self, "bad")

        self.assertEqual(nonconforming_subject("git commit -F message.txt", str(root)), "bad")


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
