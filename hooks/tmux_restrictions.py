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
    root = os.environ.get("LBWC_TMUX_CONTROL_ROOT")
    if os.environ.get("LBWC_TMUX_AGENT") != "1" or not root:
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
    return read_json(candidates[0])["tmux_execution"]["restrictions"]


def restriction(root, key, agent_id=None) -> bool:
    value = frozen(root, agent_id)[key]
    if type(value) is not bool:
        raise ValueError("frozen restriction must be boolean")
    return value


def question_allowed() -> bool:
    root = agent_root()
    return root is not None and restriction(root, "allow_agent_ask_user", os.environ.get("LBWC_TMUX_AGENT_ID"))


def git_action(data) -> bool:
    return git_write(data.get("tool_input", {}).get("command", ""))


def tool_key(data) -> str | None:
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
    key = key or tool_key(data)
    if root is None or key is None:
        return None
    try:
        allowed = restriction(root, key, os.environ.get("LBWC_TMUX_AGENT_ID"))
    except (OSError, ValueError, KeyError, TypeError) as error:
        return f"{PREFIX}{key} requires a readable frozen runtime snapshot ({error})."
    if allowed:
        return None
    message = f"{PREFIX}{key}=false denies this action inside a tmux agent pane."
    if data.get("tool_name") == "AskUserQuestion":
        message += " Send the question to the orchestrator through the bus instead."
    return message


def main() -> int:
    key = sys.argv[1] if len(sys.argv) > 1 else None
    reason = denial(json.load(sys.stdin), key)
    if reason:
        print(f"Blocked: {reason}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
