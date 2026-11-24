import os
import unittest

from hooks import user_question_guard as guard
from hooks.guard_fixtures import (
    Workspace, repo_install_reason, repo_install_workspace, seed_guard_state,
)

ROOT = "<root>"
ROOT_NAME = "<rootname>"
PARENT = ".."
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
fix(hooks): tighten guard_paths.py
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
    "git clean -n",
    "git clean --dry-run",
    "git apply --check p.diff",
    "git apply --stat p.diff",
    "git reset --soft HEAD~1",
    "git reset HEAD README.md",
    "git reset -- README.md",
    "git checkout -b new main",
    "git switch -c new main",
    "git commit -m 'fix(hooks): x'",
    "git commit -am 'fix(hooks): x'",
    "git commit -m 'touch scripts and hooks/guard_paths.py'",
    "git commit -F msg.txt",
    "gh pr create --body 'touches hooks/guard_paths.py'",
    "curl -d 'guard_paths.py' x",
    f"cp src/dispatch.py {SCRATCH}/x",
    "black dispatch.py",
    "ruff check src/dispatch.py",
    "vim dispatch.py",
    "rm build/hook_output.py",
    "npm test -- guard_paths.py",
    "cp a $X",
    "python3 /dev/stdin",
    "cat x | python3 /dev/stdin",
    "while read l; do echo $l; done < x",
    "{ cat x; }",
)
CONTROL_ROWS = (
    *ALLOWED_ROWS,
    *(("Bash", {"command": command}, "") for command in CONTROL_BASH),
    ("Grep", {"pattern": "x", "path": ROOT}, ""),
    ("Bash", {"command": "git reset --hard"}, PARENT),
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
    (f"cd {ROOT}/hooks; X=g; Y=uard_paths.py; echo x > $X$Y", SOURCE),
    ("D=hoo; echo x > ${D}ks/new.py", SOURCE),
    ("git -c merge.tool=x mergetool", SOURCE),
    ("git -c difftool.x.cmd=y difftool", SOURCE),
    ("git -c diff.x.command=y diff", SOURCE),
    ("git -c core.gitProxy=x fetch", SOURCE),
    ("git -c uploadpack.packObjectsHook=x fetch", SOURCE),
    ("git -c core.worktree=/x status", SOURCE),
    ("git -c core.attributesFile=x diff", SOURCE),
    ("git -c protocol.ext.allow=always fetch", SOURCE),
    ("git config merge.tool x", SOURCE),
    ("git bisect run make", SOURCE),
    ("git filter-branch --tree-filter 'rm x' HEAD", SOURCE),
    ("git fetch --upload-pack=x origin", SOURCE),
    ("git clone -u x repo", SOURCE),
    ("git ls-remote --upload-pack x origin", SOURCE),
    ("git grep -O x", SOURCE),
    ("git grep --open-files-in-pager=vim x", SOURCE),
    ("GIT_PAGER=x; git log", SOURCE),
    ("export GIT_PAGER=x; git log", SOURCE),
    ("bash -c 'git -c core.pager=x log'", SOURCE),
    ("(git reset --hard)", SOURCE),
    ("{ git reset --hard; }", SOURCE),
    ("if true; then git reset --hard; fi", SOURCE),
    ("! git reset --hard", SOURCE),
    ("echo $(git reset --hard)", SOURCE),
    ("bash -c 'git reset --hard'", SOURCE),
    ("awk 'BEGIN{system(\"git reset --hard\")}'", SOURCE),
    ("git read-tree -u HEAD", SOURCE),
    ("git checkout-index -f -a", SOURCE),
    ("git sparse-checkout set x", SOURCE),
    ("git bisect start", SOURCE),
    ("git submodule update", SOURCE),
    ("git submodule foreach rm x", SOURCE),
    ("python3 -m runpy hooks.dispatch", HELPER),
    ("python3 -m pdb -m hooks.dispatch", HELPER),
    ("python3 -m trace --trace hooks/dispatch.py", HELPER),
    ("python3 -m cProfile hooks/hook_batch.py", HELPER),
    ("python3 -m profile scripts/qa-phase.py", HELPER),
    ("{ bash scripts/pending-decision.sh; }", HELPER),
    ("if true; then bash scripts/hook-batch.sh; fi", HELPER),
    ("bash -c 'rm -rf $CLAUDE_PLUGIN_ROOT/hooks'", INLINE),
    ("eval 'rm -rf $CLAUDE_PLUGIN_ROOT/scripts'", INLINE),
    ("python3 -c \"import os; os.remove(os.environ['CLAUDE_PLUGIN_ROOT']+'/hooks/x')\"", INLINE),
    ("perl -e 'unlink \"$ENV{CLAUDE_PLUGIN_ROOT}/hooks/x\"'", INLINE),
    ("node -e \"require('fs').rmSync(process.env.CLAUDE_PLUGIN_ROOT+'/hooks',{recursive:true})\"", INLINE),
    (f"echo {ROOT}/hooks/x | python3 /dev/stdin", INLINE),
    (f"cat <<EOF | bash /dev/stdin\nrm {ROOT}/hooks/x\nEOF", INLINE),
)
REFUSED_ELSEWHERE = (
    ("echo x > guard_$X.py", "hooks", SOURCE),
    ('echo x > "$X"', "hooks", SOURCE),
    (f"git checkout -- {ROOT_NAME}/hooks/x", PARENT, SOURCE),
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
    ("Bash", {"command": "rm -rf .meridian"}, "", RUNTIME),
    ("Bash", {"command": f"mv .meridian {SCRATCH}/m"}, "", RUNTIME),
    ("Bash", {"command": "rm -rf ."}, "", GRANT),
    ("Bash", {"command": f"mv . {SCRATCH}/x"}, "", GRANT),
)


def placed(text: str, space: Workspace) -> str:
    places = {
        ROOT_NAME: space.root.name, ROOT: str(space.root), HOME_DIR: os.environ["HOME"],
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

    def test_writes_from_the_hooks_folder_or_the_parent_folder_are_refused(self) -> None:
        space = repo_install_workspace(self)
        for command, folder, reason in REFUSED_ELSEWHERE:
            with self.subTest(command=command, folder=folder):
                tool_input = {"command": placed(command, space)}
                self.assertEqual(repo_install_reason(space, "Bash", tool_input, folder), (0, "", reason))


class GuardStateTraversalTest(unittest.TestCase):
    def test_reads_and_moves_that_reach_runtime_or_grant_state_are_refused(self) -> None:
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
