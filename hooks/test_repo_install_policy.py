import unittest

from hooks import user_question_guard as guard
from hooks.guard_fixtures import repo_install_reason, repo_install_workspace

ROOT = "<root>"
HOME = "<home>"
TILDE = "~"

ALLOWED_BASH = (
    "git ls-files 'scripts/meridian-*'",
    "ls meridian/scripts/*.sh",
    f"jq '.[\"meridian\"]' {HOME}/.claude/plugins/installed_plugins.json",
    "bash scripts/indexer-sync.sh",
    "scripts/indexer-sync.sh",
    "bash scripts/indexer-sync.sh 2>&1 | tail -5",
    f"bash {ROOT}/scripts/meridian-config.sh init .meridian",
    "git diff hooks/guard_paths.py",
    "git log -- hooks/guard_paths.py",
    "awk '{print}' hooks/guard_paths.py",
    'rg -n "a|b" hooks/dispatch.py',
    f'python3 probe.py "bash {ROOT}/scripts/hook-batch.sh --help"',
    "python3 -m unittest discover -s hooks -t . -p 'test_*.py'",
    "cd hooks && cat guard_paths.py",
    "printf '%s' hooks/guard_paths.py",
    'bash "${CLAUDE_PLUGIN_ROOT}/scripts/meridian-conventions.sh" list .meridian',
)
ALLOWED_ROWS = (
    *(("Bash", {"command": command}) for command in ALLOWED_BASH),
    ("Glob", {"path": ROOT, "pattern": "**/*.py"}),
)
REFUSED_BASH = (
    ("bash scripts/x.sh > hooks/guard_paths.py", guard.SOURCE_READ_ONLY),
    ("cd hooks && echo x > guard_paths.py", guard.SOURCE_READ_ONLY),
    ("git diff --output=hooks/guard_paths.py", guard.SOURCE_READ_ONLY),
    ("awk '{system(\"rm x\")}' hooks/guard_paths.py", guard.SOURCE_READ_ONLY),
    ("cat plain >> .meridian/.runtime/decisions/a.json", guard.RESERVED_RUNTIME),
    ("bash scripts/indexer-sync.sh < .meridian/.runtime/decisions/s.json", guard.RESERVED_RUNTIME),
    ("source scripts/pending-decision.sh", guard.GUARD_HELPER_EXECUTION),
    ("python3 scripts/qa-phase.py inspect 01", guard.GUARD_HELPER_EXECUTION),
    ("sudo -u root bash scripts/hook-batch.sh", guard.GUARD_HELPER_EXECUTION),
    ('bash "${CLAUDE_PLUGIN_ROOT}/scripts/pending-decision.sh" create', guard.GUARD_HELPER_EXECUTION),
    ("echo hooks/guard_paths.py | xargs bash", guard.INLINE_GUARD_CODE),
    (f"cat {HOME}/.local/sta?e/meridian-g?ard/gra?t.json", guard.OWNER_GRANT),
    ("cat $HOME/.local/*/meridian-*/g*", guard.OWNER_GRANT),
)


def placed(text: str, root: str) -> str:
    return text.replace(ROOT, root).replace(HOME, TILDE)


def placed_input(tool_input: dict, root: str) -> dict:
    return {key: placed(value, root) for key, value in tool_input.items()}


class RepoInstalledAsPluginTest(unittest.TestCase):
    def test_reads_and_helper_runs_inside_the_installed_repo_are_allowed(self) -> None:
        space = repo_install_workspace(self)
        for tool, tool_input in ALLOWED_ROWS:
            with self.subTest(tool=tool, tool_input=tool_input):
                result = repo_install_reason(space, tool, placed_input(tool_input, str(space.root)))
                self.assertEqual(result, (0, "", None))

    def test_changes_helper_runs_inline_code_and_grant_access_get_their_own_reason(self) -> None:
        space = repo_install_workspace(self)
        for command, reason in REFUSED_BASH:
            with self.subTest(command=command):
                result = repo_install_reason(space, "Bash", {"command": placed(command, str(space.root))})
                self.assertEqual(result, (0, "", reason))


if __name__ == "__main__":
    unittest.main()
