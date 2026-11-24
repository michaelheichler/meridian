from __future__ import annotations

import importlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, NamedTuple, Optional
from unittest.mock import patch

HOOKS_DIR = Path(__file__).resolve().parent
ENTRY_STEM = "user_" + "question_guard"
ENTRY_POINT = HOOKS_DIR / f"{ENTRY_STEM}.py"
GUARD_PATHS_STEM = "guard_" + "paths"
QUESTION_TEXT = "Which review pace should this project use?"
PROTECTED_STEMS = (
    ENTRY_STEM,
    "decision_common",
    "decision_layout",
    "decision_io",
    "decision_records",
    "decision_store",
    "question_validation",
    GUARD_PATHS_STEM,
    "read_only_command",
    "brace_expansion",
    "path_identity",
    "qa_command",
    "shell_invocation",
    "command_view",
)


class Workspace(NamedTuple):
    root: Path
    planning: Path
    decisions: Path


def load_guard() -> Any:
    return importlib.import_module(f"hooks.{ENTRY_STEM}")


def module_path(stem: str) -> str:
    return str(HOOKS_DIR / f"{stem}.py")


def build_project(case: unittest.TestCase) -> Workspace:
    root = Path(tempfile.mkdtemp()).resolve()
    case.addCleanup(shutil.rmtree, root, True)
    home = root / "home"
    home.mkdir()
    environment = patch.dict(os.environ, {"HOME": str(home)})
    environment.start()
    case.addCleanup(environment.stop)
    planning = root / ".meridian"
    planning.mkdir()
    return Workspace(root, planning, planning / ".runtime" / "decisions")


def build_workspace(case: unittest.TestCase) -> Workspace:
    space = build_project(case)
    space.decisions.mkdir(parents=True)
    secret = space.decisions / "secret.txt"
    secret.write_text("S", encoding="utf-8")
    (space.decisions / "s10.txt").write_text("S", encoding="utf-8")
    (space.root / "rt").symlink_to(space.planning / ".runtime")
    (space.root / "pl").symlink_to(space.planning)
    os.link(secret, space.root / "link.txt")
    (space.root / "plain.txt").write_text("p", encoding="utf-8")
    (space.root / "docs").mkdir()
    return space


def tool_event(tool: str, tool_input: dict, cwd: Path) -> dict:
    return {"session_id": "sess-1", "cwd": str(cwd), "tool_name": tool, "tool_input": tool_input}


def session_event(tool_input: dict, cwd: Path, session: str) -> dict:
    return {**tool_event("AskUserQuestion", tool_input, cwd), "session_id": session}


def bash_reason(command: str, cwd: Path) -> Optional[str]:
    return tool_reason("Bash", {"command": command}, cwd)


def tool_reason(tool: str, tool_input: dict, cwd: Path) -> Optional[str]:
    return load_guard().verdict(json.dumps(tool_event(tool, tool_input, cwd)), "pretool")


def question_event(cwd: Path, session: str) -> dict:
    careful = {"label": "Careful", "description": "Check each change in detail."}
    fast = {"label": "Fast", "description": "Finish the review sooner."}
    question = {"header": "Review pace", "question": QUESTION_TEXT, "options": [fast, careful]}
    return session_event({"questions": [question]}, cwd, session)


def answer_event(cwd: Path, session: str, answer: str) -> dict:
    return session_event({"answers": {QUESTION_TEXT: answer}}, cwd, session)


def run_entry(args: list[str], stdin_text: str = "") -> subprocess.CompletedProcess:
    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
    return subprocess.run(
        [sys.executable, str(ENTRY_POINT), *args],
        input=stdin_text,
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
        check=False,
    )


def run_mode(mode: str, event: dict) -> subprocess.CompletedProcess:
    return run_entry([mode], json.dumps(event))


def installed_source_workspace(case: unittest.TestCase) -> Workspace:
    space = build_workspace(case)
    modules = tuple(module for module in HOOKS_DIR.glob("*.py")
                    if not module.name.startswith("test_")
                    and module.stem not in ("guard_fixtures", "guard_contract_cases"))
    for name in ("installed", "source"):
        hooks = space.root / name / "hooks"
        hooks.mkdir(parents=True)
        for module in modules:
            shutil.copyfile(module, hooks / module.name)
        scripts = hooks.parent / "scripts"
        scripts.mkdir()
        shutil.copyfile(HOOKS_DIR.parent / "scripts/meridian-guard.sh", scripts / "meridian-guard.sh")
    source = space.root / "source"
    shutil.copyfile(HOOKS_DIR.parent / "README.md", source / "README.md")
    subprocess.run(["git", "init", "-q", str(source)], check=True, capture_output=True)
    return space


def plugin_pretool(plugin_root: Path, cwd: Path, tool: str, tool_input: dict) -> tuple:
    environment = {**os.environ, "CLAUDE_PLUGIN_ROOT": str(plugin_root), "PYTHONDONTWRITEBYTECODE": "1"}
    result = subprocess.run(
        [sys.executable, str(plugin_root / "hooks" / ENTRY_POINT.name), "pretool"],
        input=json.dumps(tool_event(tool, tool_input, cwd)),
        cwd=cwd, env=environment, capture_output=True, text=True, timeout=30, check=False,
    )
    output = json.loads(result.stdout or "{}").get("hookSpecificOutput", {})
    return result.returncode, result.stderr, output


def installed_command_result(space: Workspace, command: str) -> tuple:
    returncode, stderr, output = plugin_pretool(
        space.root / "installed", space.root / "source", "Bash", {"command": command},
    )
    return returncode, stderr, output.get("permissionDecision")


def repo_install_workspace(case: unittest.TestCase) -> Workspace:
    space = build_project(case)
    skipped = shutil.ignore_patterns("test_*.py", "__pycache__")
    shutil.copytree(HOOKS_DIR, space.root / "hooks", ignore=skipped)
    shutil.copytree(HOOKS_DIR.parent / "scripts", space.root / "scripts", symlinks=True, ignore=skipped)
    subprocess.run(["git", "init", "-q", str(space.root)], check=True, capture_output=True)
    return space


def repo_install_reason(space: Workspace, tool: str, tool_input: dict) -> tuple:
    returncode, stderr, output = plugin_pretool(space.root, space.root, tool, tool_input)
    return returncode, stderr, output.get("permissionDecisionReason")
