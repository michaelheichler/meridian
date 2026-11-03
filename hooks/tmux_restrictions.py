from __future__ import annotations

import json
import os
from pathlib import Path
import sys

if __package__:
    from .tmux_git_policy import git_write
else:
    from tmux_git_policy import git_write

PREFIX = "tmux_execution.restrictions."


def read_json(path) -> dict:
    return json.loads(Path(path).read_text())


def agent_root() -> Path | None:
    root = os.environ.get("MERIDIAN_TMUX_CONTROL_ROOT")
    if os.environ.get("MERIDIAN_TMUX_AGENT") != "1" or not root:
        return None
    if not os.environ.get("TMUX") or not os.environ.get("TMUX_PANE"):
        return None
    return Path(root)


def frozen(root, agent_id=None) -> dict:
    candidates = []
    if agent_id:
        entry = read_json(root / ".agent-manifest.json")["agents"][agent_id]
        source = read_json(entry["contract_path"]).get("source_path")
        if source:
            candidates = [Path(source).parent / ".runtime-snapshot.json"]
    if not candidates:
        candidates = list(root.glob("phases/*/.runtime-snapshot.json"))
    if len(candidates) != 1:
        raise ValueError("one frozen runtime snapshot is required")
    snapshot = candidates[0]
    if snapshot_path_unsafe(snapshot, root):
        raise ValueError("frozen runtime snapshot path must not contain symlinks")
    return frozen_settings(read_json(snapshot))


def frozen_settings(config_snapshot) -> dict:
    # Live config.json edits could widen worker authority, so use frozen settings.
    return {
        "allow_nested_spawn": config_snapshot["tmux_execution"]["restrictions"]["allow_nested_spawn"],
        "allow_agent_git": config_snapshot["tmux_execution"]["restrictions"]["allow_agent_git"],
        "allow_agent_ask_user": config_snapshot["tmux_execution"]["restrictions"]["allow_agent_ask_user"],
    }


def snapshot_path_unsafe(snapshot, root) -> bool:
    current = snapshot
    while current != root and current != current.parent:
        if current.is_symlink():
            return True
        current = current.parent
    return current != root or root.is_symlink()


def restriction(root, key, agent_id=None) -> bool:
    value = frozen(root, agent_id)[key]
    if type(value) is not bool:
        raise ValueError("frozen restriction must be boolean")
    return value


def question_allowed() -> bool:
    root = agent_root()
    return root is not None and restriction(root, "allow_agent_ask_user", os.environ.get("MERIDIAN_TMUX_AGENT_ID"))


def git_action(data) -> bool:
    return git_write(data.get("tool_input", {}).get("command", ""))


def tool_key(data) -> str | None:
    if not isinstance(data, dict) or not isinstance(data.get("tool_input"), dict):
        raise TypeError("policy input and tool_input must be objects")
    tool = data.get("tool_name")
    if tool in {"Agent", "Task", "TaskCreate", "Workflow"}:
        return "allow_nested_spawn"
    if tool == "AskUserQuestion":
        return "allow_agent_ask_user"
    if tool == "Bash" and git_action(data):
        return "allow_agent_git"
    return None


def denial(data, key=None) -> str | None:
    root = agent_root()
    if root is None:
        return None
    try:
        key = key or tool_key(data)
        if key is None:
            return None
        allowed = restriction(root, key, os.environ.get("MERIDIAN_TMUX_AGENT_ID"))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, json.JSONDecodeError) as error:
        label = f"{PREFIX}{key}" if key else PREFIX.rstrip(".")
        return f"{label} requires valid policy input and a readable frozen runtime snapshot ({error})."
    if allowed:
        return None
    message = f"{PREFIX}{key}=false denies this action inside a tmux agent pane."
    if data.get("tool_name") == "AskUserQuestion":
        message += " Send the question to the orchestrator through the bus instead."
    return message


def main() -> int:
    key = sys.argv[1] if len(sys.argv) > 1 else None
    try:
        reason = denial(json.load(sys.stdin), key)
    except Exception as error:
        print(f"Blocked: {PREFIX.rstrip('.')} cannot validate policy input ({error})", file=sys.stderr)
        return 2
    if reason:
        print(f"Blocked: {reason}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
