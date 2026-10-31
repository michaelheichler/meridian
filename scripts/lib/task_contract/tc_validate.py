import hashlib
from pathlib import Path
from typing import Any

from tc_common import (
    COMMUNICATION_POLICIES, EXECUTION_BACKENDS, RUNTIME_KINDS, SCHEMA_2_KEYS,
    SCHEMA_3_KEYS, SCHEMA_3_ONLY_KEYS, STATES, digest_contract, fail,
    protected_worker_path, resolve_control_root, safe_capability_path,
    safe_path, safe_token, sha256_text,
)
from tc_roles import configured_team


def check_header(contract: Any, root: Path, expected_id: Any) -> Any:
    if not isinstance(contract, dict):
        fail("invalid contract")
    schema_version = contract.get("schema_version")
    expected_keys = SCHEMA_2_KEYS if schema_version == 2 else SCHEMA_3_KEYS if schema_version == 3 else set()
    if set(contract) != expected_keys:
        fail("invalid contract")
    if contract.get("contract_digest") != digest_contract(contract):
        fail("contract digest mismatch")
    if expected_id and contract.get("contract_id") != expected_id:
        fail("invalid contract")
    if contract.get("created_by") != "main" or contract.get("project_root") != str(root):
        fail("invalid contract")
    contract_id = safe_token(contract.get("contract_id"), "contract id")
    if contract.get("task_identity") != contract_id:
        fail("invalid contract")
    return schema_version


def check_team(contract: dict[str, Any]) -> list[str]:
    roles = configured_team(contract.get("role"), contract.get("team_mode"))
    if contract.get("roles") != roles or contract.get("test_dev") != ("test-dev" in roles):
        fail("invalid contract")
    return roles


def flatten_contract_allowances(contract: dict[str, Any], roles: list[str], schema_version: int) -> tuple[dict[str, Any], list[str]]:
    allowances = contract.get("allowances_by_role")
    if not isinstance(allowances, dict) or set(allowances) != set(roles):
        fail("invalid contract")
    flattened: list[str] = []
    for team_role in roles:
        paths = allowances.get(team_role)
        if not isinstance(paths, list) or any(not isinstance(path, str) for path in paths):
            fail("invalid contract")
        flattened.extend(check_allowance_paths(paths, flattened, schema_version))
    return allowances, flattened


def check_allowance_paths(paths: list[str], seen: list[str], schema_version: int) -> list[str]:
    accepted: list[str] = []
    for path in paths:
        if schema_version == 2:
            safe_path(path)
        if path in seen or path in accepted:
            fail("invalid contract")
        accepted.append(path)
    return accepted


def capability_paths_for(entries: Any) -> list[str]:
    if not isinstance(entries, list):
        fail("invalid contract")
    paths = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"access", "kind", "path"} or entry.get("access") != "write":
            fail("invalid contract")
        safe_capability_path(entry.get("path"), entry.get("kind"))
        if protected_worker_path(entry.get("path")):
            fail("invalid contract")
        paths.append(entry.get("path"))
    return paths


def check_schema3(contract: dict[str, Any], roles: list[str], root: Path) -> None:
    control_root = resolve_control_root(contract.get("control_root", ""), root)
    if str(control_root) != contract.get("control_root"):
        fail("invalid contract")
    capabilities = contract.get("capabilities_by_role")
    if not isinstance(capabilities, dict) or set(capabilities) != set(roles):
        fail("invalid contract")
    capability_paths = {role: [] for role in roles}
    for team_role in roles:
        capability_paths[team_role] = capability_paths_for(capabilities[team_role])
    if contract.get("write_allowances") != capability_paths[contract["role"]]:
        fail("invalid contract")
    if contract.get("files") != [path for team_role in roles for path in capability_paths[team_role]]:
        fail("invalid contract")
    check_schema3_enums(contract)


def check_schema3_enums(contract: dict[str, Any]) -> None:
    if contract.get("runtime_kind") not in RUNTIME_KINDS:
        fail("invalid contract")
    if contract.get("communication_policy") not in COMMUNICATION_POLICIES:
        fail("invalid contract")
    if contract.get("requested_backend") not in EXECUTION_BACKENDS:
        fail("invalid contract")
    if contract.get("resolved_backend") not in EXECUTION_BACKENDS:
        fail("invalid contract")
    if contract["requested_backend"] != contract["resolved_backend"]:
        fail("invalid contract")


def check_plan_source(contract: dict[str, Any], root: Path, plan_files: list[str], flattened: list[str]) -> None:
    source = Path(contract.get("source_path", "")).resolve()
    try:
        source.relative_to(root)
    except ValueError:
        fail("invalid contract: PLAN escapes project root")
    try:
        source_digest = hashlib.sha256(source.read_bytes()).hexdigest()
    except OSError:
        fail("invalid contract: PLAN is unavailable")
    if source_digest != contract.get("source_sha256"):
        fail("invalid contract: PLAN digest mismatch")
    if any(path not in plan_files for path in flattened):
        fail("invalid contract")


def check_source(contract: dict[str, Any], root: Path, flattened: list[str]) -> None:
    plan_files = contract.get("plan_files")
    if not isinstance(plan_files, list) or any(not isinstance(path, str) for path in plan_files):
        fail("invalid contract")
    for path in plan_files:
        safe_path(path)
    source_kind = contract.get("source_kind")
    if source_kind == "plan":
        check_plan_source(contract, root, plan_files, flattened)
        return
    if source_kind != "command" or contract.get("source_path") or contract.get("source_sha256") or plan_files:
        fail("invalid contract")


def validate_contract(contract: Any, root: Path, expected_id: Any = None, expected_job: Any = None) -> None:
    schema_version = check_header(contract, root, expected_id)
    roles = check_team(contract)
    allowances, flattened = flatten_contract_allowances(contract, roles, schema_version)
    if schema_version == 3:
        check_schema3(contract, roles, root)
    elif any(key in contract for key in SCHEMA_3_ONLY_KEYS):
        fail("invalid contract")
    if contract.get("write_allowances") != allowances[contract["role"]] or contract.get("files") != flattened:
        fail("invalid contract")
    check_source(contract, root, flattened)
    if contract.get("state") not in STATES:
        fail("invalid contract")
    if expected_job is not None and sha256_text(expected_job) != contract.get("job_sha256"):
        fail("job digest mismatch")
