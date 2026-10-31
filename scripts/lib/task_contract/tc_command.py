import time
from pathlib import Path
from typing import Any

from tc_build import build_allowances, build_capabilities, new_contract
from tc_common import (
    COMMUNICATION_POLICIES, EXECUTION_BACKENDS, RUNTIME_KINDS, fail,
    resolve_control_root, safe_id, safe_token, with_digest,
)
from tc_roles import configured_team, role_write_capable


def check_read_only_roles(options: dict[str, Any], roles: list[str], capabilities: dict[str, list[Any]]) -> None:
    for read_only_role in options["read_only_roles"]:
        safe_token(read_only_role, "role")
        if read_only_role not in roles:
            fail("read-only role is not in contract team")
        if capabilities[read_only_role]:
            fail("role declared read-only cannot also receive a write capability")


def typed_allowances(roles: list[str], capabilities: dict[str, list[dict[str, str]]]) -> tuple[dict[str, list[str]], list[str]]:
    allowances = {team_role: [item["path"] for item in capabilities[team_role]] for team_role in roles}
    return allowances, [path for team_role in roles for path in allowances[team_role]]


def check_typed_rules(options: dict[str, Any], roles: list[str], capabilities: dict[str, list[dict[str, str]]], command: str) -> None:
    if options["write_allowances"]:
        fail("typed capabilities cannot be combined with exact write allowances")
    declared = options["capabilities"] or options["role_capabilities"]
    writers = [team_role for team_role in roles if team_role not in options["read_only_roles"]]
    if not declared and any(role_write_capable(team_role) for team_role in writers):
        fail("typed contract requires at least one capability")
    paths = [item["path"] for role_caps in capabilities.values() for item in role_caps]
    if "." in paths and command != "team":
        fail("repository root capability is only valid for team")


def command_backends(options: dict[str, Any], typed: bool) -> dict[str, str]:
    requested = options["requested_backend"] or "in_process"
    resolved = options["resolved_backend"] or requested
    runtime_kind = options["runtime_kind"] or "native-team"
    policy = options["communication_policy"] or "native-team"
    if not typed and (options["requested_backend"] or options["resolved_backend"]):
        fail("execution backends require a schema 3 contract")
    if typed and runtime_kind not in RUNTIME_KINDS:
        fail("invalid runtime_kind")
    if typed and policy not in COMMUNICATION_POLICIES:
        fail("invalid communication_policy")
    if typed and requested not in EXECUTION_BACKENDS:
        fail("invalid requested_backend")
    if typed and resolved not in EXECUTION_BACKENDS:
        fail("invalid resolved_backend")
    if typed and requested != resolved:
        fail("requested_backend and resolved_backend must match")
    return {"requested_backend": requested, "resolved_backend": resolved,
            "runtime_kind": runtime_kind, "communication_policy": policy}


def command_allowances(options: dict[str, Any], roles: list[str], role: str, typed: bool, capabilities: dict[str, list[dict[str, str]]]) -> tuple[dict[str, list[str]], list[str]]:
    if typed:
        return typed_allowances(roles, capabilities)
    return build_allowances(roles, role, options["write_allowances"], options["role_write_allowances"])


def command_identity(options: dict[str, Any]) -> tuple[str, str, str]:
    role = safe_token(options["role"], "role")
    command = safe_token(options["command"], "command")
    group = safe_token(options["group"] or f"run-{time.time_ns()}", "group")
    if not options["team"]:
        fail("--team is required")
    if not options["job"]:
        fail("--job is required")
    return role, command, group


def command_core(task_name: str, options: dict[str, Any], identity: tuple[str, str, str]) -> dict[str, Any]:
    role, command, group = identity
    return {
        "contract_id": safe_id("cmd", command, task_name, group), "source_kind": "command",
        "source_path": "", "source_sha256": "", "command_name": command, "phase": "",
        "task_name": task_name, "group": group, "team": options["team"], "role": role,
        "plan_files": [], "job": options["job"], "action": options["job"],
        "verify": "", "done": "", "strategy": "command",
    }


def command_contract(root: Path, task_name: str, options: dict[str, Any]) -> dict[str, Any]:
    identity = command_identity(options)
    role, command = identity[0], identity[1]
    roles = configured_team(role, options["team"])
    capabilities = build_capabilities(roles, role, options["capabilities"], options["role_capabilities"])
    check_read_only_roles(options, roles, capabilities)
    typed = bool(options["capabilities"] or options["role_capabilities"] or options["control_root"])
    allowances, files = command_allowances(options, roles, role, typed, capabilities)
    if typed:
        check_typed_rules(options, roles, capabilities, command)
    control_root = resolve_control_root(options["control_root"], root) if typed else None
    backends = command_backends(options, typed)
    core = command_core(task_name, options, identity)
    core.update({"roles": roles, "files": files, "allowances": allowances})
    contract = new_contract(root, core)
    if typed:
        contract.update(backends)
        contract.update({"capabilities_by_role": capabilities,
                         "control_root": str(control_root), "schema_version": 3})
    return with_digest(contract)
