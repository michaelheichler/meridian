from __future__ import annotations

import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

TIERS = frozenset({"quick", "standard", "deep"})
HOSTS = frozenset({"claude", "codex"})
MAX_VERDICT_BYTES = 24000
PHASE = re.compile(r"[0-9]{1,3}", re.ASCII)
TASK = re.compile(r"cmd-qa-qa-[0-9]{2,3}-[a-f0-9]{12}-phase", re.ASCII)
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*", re.ASCII)
CLAUDE_QA_AGENT = "meridian:phase-qa"
CONTRACT_LINE = re.compile(r"^Meridian-Contract: (\S+)$", re.MULTILINE)
__all__ = ["CLAUDE_QA_AGENT", "claim_qa_worker", "permits_qa_command", "valid_arguments"]

AGENT_FIELDS = (
    "agent_id", "agentId", "agent_type", "agentType", "subagent_type", "subagentType",
)


def valid_arguments(args: list[str]) -> bool:
    if len(args) < 2 or not PHASE.fullmatch(args[1]):
        return False
    operation = args[0]
    if operation == "inspect":
        return len(args) == 2
    if operation == "start":
        return len(args) == 4 and args[2] in TIERS and args[3] in HOSTS
    if operation == "route":
        return len(args) == 3 and valid_ownership(args[2])
    if operation != "publish" or len(args) != 4 or not TASK.fullmatch(args[2]):
        return False
    if len(args[3].encode()) > MAX_VERDICT_BYTES:
        return False
    try:
        verdict = json.loads(args[3])
    except (ValueError, RecursionError):
        return False
    return isinstance(verdict, dict)


def valid_ownership(value: str) -> bool:
    if len(value.encode()) > MAX_VERDICT_BYTES:
        return False
    try:
        rows = json.loads(value)
    except (ValueError, RecursionError):
        return False
    return isinstance(rows, list) and bool(rows) and all(
        isinstance(row, dict) and set(row) == {"task_id", "owners"}
        and isinstance(row["task_id"], str) and TOKEN.fullmatch(row["task_id"])
        and isinstance(row["owners"], list)
        and all(isinstance(role, str) and TOKEN.fullmatch(role) for role in row["owners"])
        for row in rows
    )


def trusted_python(value: str) -> bool:
    path = Path(value)
    return value == "python3" or (
        path.is_absolute() and path.resolve() == Path(sys.executable).resolve()
    )


def permits_qa_command(
    data: dict, cwd: Path | None, planning: Path | None, roots: set[Path],
) -> bool:
    if data.get("tool_name") != "Bash" or cwd is None or planning is None or planning.parent != cwd:
        return False
    command = data["tool_input"].get("command")
    if not isinstance(command, str) or len(command) > MAX_VERDICT_BYTES * 2:
        return False
    if "\n" in command or "\r" in command or "\x00" in command:
        return False
    try:
        words = shlex.split(command)
    except ValueError:
        return False
    if len(words) < 6 or words[1:3] != ["-I", "-B"]:
        return False
    canonical = shlex.join(words)
    if command.strip() not in {canonical, canonical.replace("'\"'\"'", "'\\''")}:
        return False
    if not trusted_python(words[0]):
        return False
    if not any(words[3] == str(root / "scripts" / "qa-phase.py") for root in roots):
        return False
    if words[4] not in {"inspect", "route"} and any(data.get(field) for field in AGENT_FIELDS):
        return False
    return valid_arguments(words[4:])


def claim_qa_worker(data: dict, planning: Path | None) -> str | None:
    tool_input = data["tool_input"]
    if data["tool_name"] != "Agent" or tool_input.get("subagent_type") != CLAUDE_QA_AGENT:
        return None
    prompt = tool_input.get("prompt")
    ids = CONTRACT_LINE.findall(prompt) if isinstance(prompt, str) else []
    if planning is None or len(ids) != 1 or not TASK.fullmatch(ids[0]) or any(
        data.get(field) for field in AGENT_FIELDS
    ):
        return "Meridian phase QA requires a dispatched main-session QA contract."
    runner = Path(__file__).resolve().parents[1] / "scripts" / "task-contract.sh"
    root = str(planning.parent)
    try:
        contract = json.loads(subprocess.check_output(
            ["/bin/bash", str(runner), "read", root, ids[0]],
            text=True, stderr=subprocess.DEVNULL, timeout=2,
        ))
        if contract["role"] != "qa" or contract["command_name"] != "qa" or contract["state"] != "dispatched":
            return "Meridian phase QA requires a dispatched main-session QA contract."
        subprocess.check_output(
            ["/bin/bash", str(runner), "state", root, ids[0], "running"],
            stderr=subprocess.DEVNULL, timeout=2,
        )
    except (OSError, KeyError, ValueError, subprocess.SubprocessError):
        return "Meridian could not claim this QA contract. Start a new phase QA run."
    return None
