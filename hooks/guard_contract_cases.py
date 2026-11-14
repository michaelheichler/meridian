import json
import os
import subprocess
import time
from datetime import datetime, timezone
from itertools import product
from pathlib import Path
from unittest.mock import patch

from hooks import guard_unlock
from hooks.guard_fixtures import HOOKS_DIR, build_workspace, tool_reason

DURATION_SECONDS = {"30m": 1800, "2h": 7200, "12h": 43200}
CLI_ROWS = (("30m", "allow", (0, True)), ("2h", "allow", (0, True)),
            ("12h", "allow", (0, True)), ("13h", "allow", (2, None)),
            ("721m", "allow", (2, None)), ("0m", "allow", (2, None)),
            ("1h", "status", (0, True, True)), ("1h", "revoke", (0, False, True)))
UNLOCKED_DENIALS = (("Read", {"file_path": "rt/decisions/secret.txt"}),
                   ("Write", {"file_path": "rt/decisions/new.txt"}),
                   ("Bash", {"command": "cat rt/decisions/secret.txt"}),
                   ("Edit", {"file_path": "installed/hooks/guard_unlock.py"}),
                   ("Bash", {"command": "bash scripts/pending-decision.sh"}),
                   ("Bash", {"command": "cat ~/.local/state/meridian-guard/grant.json"}),
                   ("Read", {"file_path": ".runtime/decisions/other.json"}),
                   ("Read", {"file_path": ".hook-transitions"}),
                   ("Grep", {"path": "rt", "pattern": "S"}),
                   ("Glob", {"path": "rt", "pattern": "**/*"}),
                   ("NotebookEdit", {"notebook_path": "rt/decisions/new.ipynb"}))
UNLOCKED_ALLOWANCES = (("Write", {"file_path": "installed/hooks/new.py"}),
                       ("Bash", {"command": "git add installed/hooks/guard_paths.py"}),
                       ("Bash", {"command": "printf x > installed/hooks/guard_paths.py"}))

COMMAND_ROWS = (
    ("source-stage", "git add hooks/guard_paths.py", False),
    ("source-shell-write", "printf x > hooks/guard_paths.py", False),
    ("source-compound-read", "cd {root} && cat hooks/guard_paths.py", False),
    ("source-compound-stage", "cd {root} && git add hooks/guard_paths.py", False),
    ("installed-parent-rename", "mv {installed} moved", True),
    ("installed-cd", "cd {installed} && printf x > hooks/guard_paths.py", True),
    ("installed-pushd", "pushd {installed} && git add hooks/guard_paths.py", True),
    ("installed-git-C", "git -C {installed} add hooks/guard_paths.py", True),
    ("dynamic-cd-fallback", "cd \"$DEST\" && printf x > hooks/guard_paths.py", True),
    ("ancestor-listing", "ls ~", False),
    ("cli-source-read", "cat {installed}/scripts/meridian-guard.sh", False),
    ("unlock-source-read", "cat {installed}/hooks/guard_unlock.py", False),
    ("cli-free-text", "echo 'Use meridian-guard to manage owner intent'", False),
    ("unlock-import", "python3 -c 'import guard_unlock'", True),
    ("unlock-from-import", "python3 -c 'from hooks import guard_unlock'", True),
    ("unlock-module", "python3 -m hooks.guard_unlock status", True),
    ("unlock-bare-module", "python3 -m guard_unlock status", True),
    ("embedded-bash", "bash -c 'cat {installed}/hooks/hooks.json'", True),
    ("embedded-python", "python3 -c 'open(\"{installed}/hooks/hooks.json\").read()'", True),
    ("embedded-perl", "perl -e 'open F, \"{installed}/hooks/hooks.json\"'", True),
    ("embedded-eval", "eval 'cat {installed}/hooks/hooks.json'", True),
    ("interpreter-chdir", "python3 -c 'import os; os.chdir(\"{installed}/hooks\"); open(\"hooks.json\").read()'", True),
    ("grant-glob", "cat ~/.local/state/meridian-guard/*.json", True),
    ("grant-bracket", "cat ~/.local/state/meridian-guar[d]/grant.json", True),
    ("grant-variable", "cat ${{HOME}}/.local/state/meridian-guard/grant.json", True),
)
WRAPPERS = ("source {script}", ". {script}", "env bash {script}", "sudo bash {script}",
            "nohup bash {script}", "time bash {script}", "xargs bash {script}",
            "bash -c 'bash {script}'", "bash -o errexit {script}")
GRANT_KINDS = ("valid", "expired", "far-future", "string", "boolean", "float", "list", "extra-key",
               "malformed", "public-grant", "public-directory", "symlink-grant", "symlink-directory", "directory-grant")


def contract_workspace(case) -> object:
    space = build_workspace(case)
    installed = space.root / "installed"
    for tree in ("hooks", "scripts"):
        (installed / tree).mkdir(parents=True)
        (space.root / tree).mkdir()
    for relative in ("hooks/guard_paths.py", "hooks/hooks.json", "hooks/guard_unlock.py",
                     "scripts/meridian-guard.sh", "scripts/pending-decision.sh"):
        (installed / relative).touch()
        (space.root / relative).touch()
    (space.root / "installed-alias").symlink_to(installed, target_is_directory=True)
    (space.root / "source-alias.py").symlink_to(installed / "hooks/guard_paths.py")
    os.link(installed / "hooks/guard_paths.py", space.root / "hard-alias.py")
    environment = patch.dict(os.environ, {"CLAUDE_PLUGIN_ROOT": str(space.root / "installed-alias" / ".")})
    environment.start()
    case.addCleanup(environment.stop)
    return space


def source_policy_rows(space) -> list:
    installed = space.root / "installed"
    source = "hooks/guard_paths.py"
    rows = [
        ("source-edit", "Edit", {"file_path": source}, space.root, False),
        ("source-write", "Write", {"file_path": source}, space.root, False),
        ("unlock-source-edit", "Edit", {"file_path": "hooks/guard_unlock.py"}, space.root, False),
        ("cli-source-write", "Write", {"file_path": "scripts/meridian-guard.sh"}, space.root, False),
        ("configured-canonical-root", "Edit", {"file_path": str(installed / source)}, space.root, True),
        ("running-root", "Write", {"file_path": str(HOOKS_DIR / "guard_paths.py")}, space.root, True),
        ("installed-directory", "Write", {"file_path": str(installed / "hooks")}, space.root, True),
        ("installed-new-file", "Write", {"file_path": str(installed / "hooks/new.py")}, space.root, True),
        ("symlink-alias", "Edit", {"file_path": "source-alias.py"}, space.root, True),
        ("hardlink-alias", "Write", {"file_path": "hard-alias.py"}, space.root, True),
    ]
    rows.extend((label, "Bash", {"command": command.format(root=space.root, installed=installed)}, space.root, denied)
                for label, command, denied in COMMAND_ROWS)
    rows.append(("installed-hooks-pwd", "Bash", {"command": "pwd"}, installed / "hooks", False))
    scripts = ("scripts/pending-decision.sh", "scripts/hook-batch.sh", "hooks/guard_paths.py")
    for origin, relative, wrapper in product((space.root, installed), scripts, WRAPPERS):
        command = wrapper.format(script=origin / relative)
        rows.append((command, "Bash", {"command": command}, space.root, True))
    return rows


def grant_directory() -> Path:
    directory = guard_unlock.state_directory()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    return directory


def write_grant(kind) -> int:
    directory = grant_directory()
    grant = directory / "grant.json"
    expiry = int(time.time()) + 1800
    payloads = {
        "valid": {"expires_at": expiry},
        "expired": {"expires_at": int(time.time()) - 1},
        "far-future": {"expires_at": int(time.time()) + 13 * 3600},
        "string": {"expires_at": str(expiry)},
        "boolean": {"expires_at": True},
        "float": {"expires_at": float(expiry)},
        "list": [expiry],
        "extra-key": {"expires_at": expiry, "allow": True},
    }
    grant.write_text(json.dumps(payloads.get(kind, payloads["valid"])))
    grant.chmod(0o600)
    alter_grant(kind, directory, grant)
    return expiry


def alter_grant(kind, directory, grant) -> None:
    if kind == "malformed":
        grant.write_text("{")
    if kind == "public-grant":
        grant.chmod(0o644)
    if kind == "public-directory":
        directory.chmod(0o755)
    if kind == "symlink-grant":
        target = directory.parent / "other-grant.json"
        grant.rename(target)
        grant.symlink_to(target)
    if kind == "symlink-directory":
        target = directory.with_name("other-state")
        directory.rename(target)
        directory.symlink_to(target, target_is_directory=True)
    if kind == "directory-grant":
        grant.unlink()
        grant.mkdir(mode=0o700)


def grant_policy_result(case, kind) -> bool:
    space = contract_workspace(case)
    write_grant(kind)
    return tool_reason("Edit", {"file_path": str(space.root / "installed/hooks/guard_paths.py")}, space.root) is not None


def cli_result(case, duration, action) -> tuple:
    space = build_workspace(case)
    cli = HOOKS_DIR.parent / "scripts/meridian-guard.sh"
    environment = dict(os.environ)
    environment.pop("CLAUDE_PLUGIN_ROOT", None)
    started = int(time.time())
    allowed = subprocess.run(["bash", str(cli), "allow", "--for", duration], cwd=space.root,
                             env=environment, capture_output=True, text=True, check=False)
    expiry = guard_unlock.active_expiry()
    if action == "allow":
        seconds = DURATION_SECONDS.get(duration, 0)
        lifetime = None if expiry is None else started + seconds <= expiry <= int(time.time()) + seconds
        return allowed.returncode, lifetime
    stamp = datetime.fromtimestamp(expiry, timezone.utc).isoformat()
    result = subprocess.run(["bash", str(cli), action], cwd=space.root, env=environment,
                            capture_output=True, text=True, check=False)
    reported = stamp in result.stdout if action == "status" else bool(result.stdout.strip())
    return result.returncode, guard_unlock.grant_path().exists(), reported


def policy_results(case) -> object:
    space = contract_workspace(case)
    for label, tool, tool_input, cwd, denied in source_policy_rows(space):
        yield label, tool_reason(tool, tool_input, cwd) is not None, denied
    with patch.dict(os.environ, {"CLAUDE_PLUGIN_ROOT": str(space.root / "missing")}):
        reason = tool_reason("Write", {"file_path": "${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json"}, space.root)
        yield "unresolved-root-hooks-json", reason is not None, True


def grant_results(case) -> object:
    for kind in GRANT_KINDS:
        yield "grant-" + kind, grant_policy_result(case, kind), kind != "valid"
    space = contract_workspace(case)
    write_grant("valid")
    for tool, tool_input in UNLOCKED_DENIALS:
        yield ("unlocked", tool, tool_input), tool_reason(tool, tool_input, space.root) is not None, True
    for tool, tool_input in UNLOCKED_ALLOWANCES:
        yield ("unlocked", tool, tool_input), tool_reason(tool, tool_input, space.root) is not None, False
    for duration, action, expected in CLI_ROWS:
        yield (duration, action), cli_result(case, duration, action), expected
