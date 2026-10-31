import json
import os
from pathlib import Path
from typing import Any

from tc_common import fail, safe_token


def role_defaults() -> dict[str, Any]:
    path = Path(os.environ["TASK_CONTRACT_SCRIPT_DIR"]) / ".." / "templates" / "agent-roles" / "defaults.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        fail("role configuration is unavailable")
    if not isinstance(data, dict):
        fail("role configuration is malformed")
    return data


def role_write_capable(role_name: str) -> bool:
    entry = role_defaults().get(role_name, {})
    disallowed = entry.get("disallowedTools", "") if isinstance(entry, dict) else ""
    tokens = {token.strip() for token in disallowed.split(",")}
    return not {"Write", "Edit"}.issubset(tokens)


def team_roles(defaults: dict[str, Any], role: str, mode: Any) -> list[str]:
    if mode == "solo":
        return [role]
    if mode == "pair":
        critic = defaults[role].get("pairsWith")
        if not isinstance(critic, str) or not critic:
            fail("role has no configured pair")
        return [role, critic]
    if mode == "trio":
        roles = defaults.get("trios", {}).get(role)
        if not isinstance(roles, list) or len(roles) < 2 or any(not isinstance(item, str) for item in roles):
            fail("role has no configured trio")
        return roles
    fail("invalid team mode")


def configured_team(role: Any, mode: Any) -> list[str]:
    safe_token(role, "role")
    defaults = role_defaults()
    if role not in defaults or not isinstance(defaults[role], dict):
        fail("unknown role")
    roles = team_roles(defaults, role, mode)
    if len(roles) != len(set(roles)):
        fail("role configuration is malformed")
    return roles


def default_team_mode(role: str) -> str:
    defaults = role_defaults()
    entry = defaults.get(role)
    if isinstance(entry, dict) and isinstance(entry.get("pairsWith"), str):
        return "pair"
    return "solo"
