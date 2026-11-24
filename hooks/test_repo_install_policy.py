import os
import unittest

from hooks import user_question_guard as guard
from hooks.guard_fixtures import (
    Workspace, repo_install_reason, repo_install_workspace, seed_guard_state,
)

ROOT = "<root>"
HOME = "<home>"
HOME_DIR = "<homedir>"
SCRATCH = "<tmp>"
TILDE = "~"
SOURCE = guard.SOURCE_READ_ONLY
HELPER = guard.GUARD_HELPER_EXECUTION
INLINE = guard.INLINE_GUARD_CODE
RUNTIME = guard.RESERVED_RUNTIME
GRANT = guard.OWNER_GRANT
COMMIT_WITH_HEREDOC = """git commit -m "$(cat <<'EOF'
Tighten the guard_paths.py checks
EOF
)\""""

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
    *(("Bash", {"command": command}, "") for command in ALLOWED_BASH),
    ("Glob", {"path": ROOT, "pattern": "**/*.py"}, ""),
)
CONTROL_BASH = (
    "rg x .",
    f"rg x {ROOT}",
    f"rm {ROOT}/hooks/zz_*.py",
    "git config --get user.name",
    "git config user.name x",
    "git checkout -b feature",
    "git stash list",
    "git status",
    "echo $PATH",
    COMMIT_WITH_HEREDOC,
    "python3 -c 'import json; print(1)'",
)
CONTROL_ROWS = (
    *ALLOWED_ROWS,
    *(("Bash", {"command": command}, "") for command in CONTROL_BASH),
    ("Grep", {"pattern": "x", "path": ROOT}, ""),
)
REFUSED_BASH = (
    ("bash scripts/x.sh > hooks/guard_paths.py", SOURCE),
    ("cd hooks && echo x > guard_paths.py", SOURCE),
    ("git diff --output=hooks/guard_paths.py", SOURCE),
    ("awk '{system(\"rm x\")}' hooks/guard_paths.py", SOURCE),
    (f"cd {ROOT}/hooks; echo x > guard_paths.py", SOURCE),
    (f"cd {ROOT}/hooks&&echo x > guard_paths.py", SOURCE),
    (f'cd "{ROOT}/hooks"; echo x > guard_paths.py', SOURCE),
    (f"cp {SCRATCH}/hosts {ROOT}/hooks/guard_paths.py$E", SOURCE),
    (f"echo x > {ROOT}/hooks/$'guard_paths.py'", SOURCE),
    (f"echo x > {ROOT}/hooks/$(echo new).py", SOURCE),
    (f"tee {ROOT}/hooks$E/new", SOURCE),
    (f"touch {ROOT}/hooks/new$E", SOURCE),
    (f"touch {ROOT}/ho$X/a", SOURCE),
    ("echo x > $D/guard_paths.py", SOURCE),
    (f"awk 'BEGIN{{print \"x\" > \"{ROOT}/hooks/guard_paths.py\"}}'", SOURCE),
    (f"flock {SCRATCH}/l sh -c 'echo x > {ROOT}/hooks/a'", SOURCE),
    (f"env -S \"sh -c 'rm {ROOT}/hooks/a'\"", SOURCE),
    (f"sed -n 'w {ROOT}/hooks/a' {SCRATCH}/hosts", SOURCE),
    (f"sed '1e rm {ROOT}/hooks/a' x", SOURCE),
    (f"php -r 'unlink(\"{ROOT}/hooks/a\");'", SOURCE),
    (f"ssh host \"cat {ROOT}/hooks/a\"", SOURCE),
    (f"python3 -m pytest --junitxml={ROOT}/hooks/guard_paths.py", SOURCE),
    (f"python3 -m pytest --basetemp={ROOT}/hooks", SOURCE),
    (f"bash {SCRATCH}/any/scripts/x.sh {ROOT}/hooks/guard_paths.py", SOURCE),
    (f"bash {ROOT}/scripts/indexer-sync.sh {ROOT}/hooks/guard_paths.py", SOURCE),
    (f"cp {SCRATCH}/hosts {ROOT}/h*oks/x.py", SOURCE),
    (f"cp {SCRATCH}/hosts {ROOT}/h??ks/x.py", SOURCE),
    ("git -c core.pager='!rm x' log", SOURCE),
    ("git -c alias.x='!rm x' x", SOURCE),
    ("git config alias.y '!rm x'", SOURCE),
    ("git config core.pager less", SOURCE),
    ("GIT_PAGER='rm x' git log", SOURCE),
    ("git reset --hard", SOURCE),
    ("git checkout -- .", SOURCE),
    ("git restore .", SOURCE),
    ("git stash", SOURCE),
    ("git clean -fdx", SOURCE),
    (f"git -C {ROOT} pull", SOURCE),
    ("cat plain >> .meridian/.runtime/decisions/a.json", RUNTIME),
    ("bash scripts/indexer-sync.sh < .meridian/.runtime/decisions/s.json", RUNTIME),
    ("source scripts/pending-decision.sh", HELPER),
    ("python3 scripts/qa-phase.py inspect 01", HELPER),
    ("sudo -u root bash scripts/hook-batch.sh", HELPER),
    ('bash "${CLAUDE_PLUGIN_ROOT}/scripts/pending-decision.sh" create', HELPER),
    (f"bash {ROOT}/scripts/$'pending-decision.sh'", HELPER),
    ("awk 'BEGIN{system(\"bash scripts/pending-decision.sh\")}'", HELPER),
    (f"bash {ROOT}/scripts/pending-dec*.sh", HELPER),
    (f"bash {ROOT}/scripts/hook-b*.sh", HELPER),
    ("python3 -m hooks.user_question_guard pretool", HELPER),
    ("python3 -m hooks.dispatch", HELPER),
    ("python3 -mhook_batch", HELPER),
    ("echo hooks/guard_paths.py | xargs bash", INLINE),
    (f"find / -exec sh -c 'rm {ROOT}/hooks/a' \\;", INLINE),
    ("python3 -c 'import user_question_guard'", INLINE),
    (f"cat {HOME}/.local/sta?e/meridian-g?ard/gra?t.json", GRANT),
    ("cat $HOME/.local/*/meridian-*/g*", GRANT),
)
STATE_ROWS = (
    ("Bash", {"command": "grep -rn x ."}, "", RUNTIME),
    ("Bash", {"command": "find .meridian -type f -exec cat {} +"}, "", RUNTIME),
    ("Bash", {"command": "ls -R .meridian"}, "", RUNTIME),
    ("Bash", {"command": "rg --hidden x ."}, "", RUNTIME),
    ("Bash", {"command": f"cp -r .meridian {SCRATCH}/copy"}, "", RUNTIME),
    ("Grep", {"pattern": "x", "path": ".meridian"}, "", RUNTIME),
    ("Grep", {"pattern": "x"}, ".meridian", RUNTIME),
    ("Bash", {"command": f"grep -r . {HOME}/.local"}, "", GRANT),
    ("Bash", {"command": f"diff -r {HOME}/.local {SCRATCH}"}, "", GRANT),
    ("Bash", {"command": f"find {HOME}/.local -name grant.json"}, "", GRANT),
    ("Grep", {"pattern": "x", "path": f"{HOME_DIR}/.local/state"}, "", GRANT),
)


def placed(text: str, space: Workspace) -> str:
    places = {
        ROOT: str(space.root), HOME_DIR: os.environ["HOME"],
        HOME: TILDE, SCRATCH: str(space.root.parent / "scratch"),
    }
    for placeholder, value in places.items():
        text = text.replace(placeholder, value)
    return text


def placed_input(tool_input: dict, space: Workspace) -> dict:
    return {key: placed(value, space) for key, value in tool_input.items()}


def stateful_workspace(case: unittest.TestCase) -> Workspace:
    space = repo_install_workspace(case)
    seed_guard_state(space)
    return space


class RepoInstalledAsPluginTest(unittest.TestCase):
    def test_reads_and_helper_runs_inside_the_installed_repo_are_allowed(self) -> None:
        space = repo_install_workspace(self)
        for tool, tool_input, folder in ALLOWED_ROWS:
            with self.subTest(tool=tool, tool_input=tool_input):
                result = repo_install_reason(space, tool, placed_input(tool_input, space), folder)
                self.assertEqual(result, (0, "", None))

    def test_changes_helper_runs_inline_code_and_grant_access_get_their_own_reason(self) -> None:
        space = repo_install_workspace(self)
        for command, reason in REFUSED_BASH:
            with self.subTest(command=command):
                result = repo_install_reason(space, "Bash", {"command": placed(command, space)})
                self.assertEqual(result, (0, "", reason))


class GuardStateTraversalTest(unittest.TestCase):
    def test_recursive_reads_that_reach_runtime_or_grant_state_are_refused(self) -> None:
        space = stateful_workspace(self)
        for tool, tool_input, folder, reason in STATE_ROWS:
            with self.subTest(tool=tool, tool_input=tool_input, folder=folder):
                result = repo_install_reason(space, tool, placed_input(tool_input, space), folder)
                self.assertEqual(result, (0, "", reason))

    def test_ordinary_reads_and_git_use_stay_allowed_next_to_guard_state(self) -> None:
        space = stateful_workspace(self)
        for tool, tool_input, folder in CONTROL_ROWS:
            with self.subTest(tool=tool, tool_input=tool_input):
                result = repo_install_reason(space, tool, placed_input(tool_input, space), folder)
                self.assertEqual(result, (0, "", None))


if __name__ == "__main__":
    unittest.main()
