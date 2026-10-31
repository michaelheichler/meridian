import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from tc_common import (
    COMMUNICATION_POLICIES, EXECUTION_BACKENDS, RUNTIME_KINDS, AllowMap,
    AllowResult, CapMap, JsonMap, Team, fail, protected_worker_path,
    resolve_control_root, safe_capability_path, safe_path, sha256_text,
)

CapPairs = list[tuple[str, str]]
RoleCaps = list[tuple[str, str, str]]
PASSTHROUGH = (
    "source_kind", "source_path", "source_sha256", "command_name", "phase",
    "task_name", "plan_files", "files", "roles", "role", "action", "verify",
    "done", "strategy",
)


@dataclass(frozen=True)
class AllowanceSpec:
    team: Team
    primary_paths: list[str]
    role_specs: list[str]
    allowed_paths: Any = None


@dataclass(frozen=True)
class BackendChoice:
    requested: str
    resolved: str
    runtime_kind: str
    policy: str


def new_contract(root: Path, core: JsonMap) -> JsonMap:
    contract = {key: core[key] for key in PASSTHROUGH}
    contract.update({
        "contract_id": core["contract_id"],
        "schema_version": 2,
        "created_by": "main",
        "project_root": str(root),
        "task_identity": core["contract_id"],
        "group_name": core["group"],
        "team_mode": core["team"],
        "test_dev": "test-dev" in core["roles"],
        "write_allowances": core["allowances"][core["role"]],
        "allowances_by_role": core["allowances"],
        "job_sha256": sha256_text(core["job"]),
        "state": "planned",
        "contract_digest": "",
    })
    return contract


def checked_grant(path: str) -> str:
    if protected_worker_path(path):
        fail("protected path cannot be granted to a generated worker")
    return path


def grant_role_specs(allowances: AllowMap, role_specs: list[str]) -> None:
    for spec in role_specs:
        if ":" not in spec:
            fail("invalid role write allowance")
        role, path = spec.split(":", 1)
        if role not in allowances:
            fail("allowance role is not in contract team")
        safe_path(path)
        allowances[role].append(checked_grant(path))


def flatten_allowances(roles: list[str], allowances: AllowMap, allowed_paths: Any) -> list[str]:
    flattened: list[str] = []
    for path in (item for role in roles for item in allowances[role]):
        if path in flattened:
            fail("duplicate contract allowance")
        if allowed_paths is not None and path not in allowed_paths:
            fail("allowance is not declared by PLAN")
        flattened.append(path)
    return flattened


def build_allowances(spec: AllowanceSpec) -> AllowResult:
    roles = spec.team.roles
    allowances: AllowMap = {role: [] for role in roles}
    for path in spec.primary_paths:
        safe_path(path)
        allowances[spec.team.primary].append(checked_grant(path))
    grant_role_specs(allowances, spec.role_specs)
    return allowances, flatten_allowances(roles, allowances, spec.allowed_paths)


def capability_entry(kind: str, path: str) -> dict[str, str]:
    safe_capability_path(path, kind)
    checked_grant(path)
    return {"access": "write", "kind": kind, "path": path}


def reject_duplicate_capabilities(roles: list[str], capabilities: CapMap) -> None:
    seen = set()
    for role, entry in ((role, item) for role in roles for item in capabilities[role]):
        identity = (role, entry["kind"], entry["path"])
        if identity in seen:
            fail("duplicate contract capability")
        seen.add(identity)


def build_capabilities(team: Team, primary_capabilities: CapPairs, role_specs: RoleCaps) -> CapMap:
    capabilities: CapMap = {role: [] for role in team.roles}
    for kind, path in primary_capabilities:
        capabilities[team.primary].append(capability_entry(kind, path))
    for role, kind, path in role_specs:
        if role not in team.roles:
            fail("capability role is not in contract team")
        capabilities[role].append(capability_entry(kind, path))
    reject_duplicate_capabilities(team.roles, capabilities)
    return capabilities


def capabilities_from_allowances(allowances: AllowMap) -> CapMap:
    return {
        role: [{"access": "write", "kind": "file", "path": path} for path in paths]
        for role, paths in allowances.items()
    }


def schema3_plan_requested(options: JsonMap) -> bool:
    flags = (
        bool(options["requested_backend"]),
        bool(options["resolved_backend"]),
        bool(options["control_root"]),
    )
    if any(flags) != all(flags):
        fail("schema 3 open requires --requested-backend, --resolved-backend, and --control-root")
    return all(flags)


def check_plan_backends(choice: BackendChoice) -> None:
    if choice.requested not in EXECUTION_BACKENDS:
        fail("invalid requested_backend")
    if choice.resolved not in EXECUTION_BACKENDS:
        fail("invalid resolved_backend")
    if choice.requested != choice.resolved:
        fail("requested_backend and resolved_backend must match")
    if choice.runtime_kind not in RUNTIME_KINDS:
        fail("invalid runtime_kind")
    if choice.policy not in COMMUNICATION_POLICIES:
        fail("invalid communication_policy")


def plan_schema3_fields(options: JsonMap, root: Path, allowances: AllowMap) -> JsonMap:
    choice = BackendChoice(
        options["requested_backend"], options["resolved_backend"],
        options["runtime_kind"] or "native-team",
        options["communication_policy"] or "native-team",
    )
    check_plan_backends(choice)
    return {
        "capabilities_by_role": capabilities_from_allowances(allowances),
        "communication_policy": choice.policy,
        "control_root": str(resolve_control_root(options["control_root"], root)),
        "runtime_kind": choice.runtime_kind,
        "requested_backend": choice.requested,
        "resolved_backend": choice.resolved,
        "schema_version": 3,
    }


def assert_contract_matches_snapshot(path: str, contract: JsonMap) -> None:
    try:
        snapshot = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        fail("runtime snapshot is malformed")
    if not isinstance(snapshot, dict):
        fail("runtime snapshot is malformed")
    if contract.get("schema_version") != 3:
        fail("snapshot assertion requires a schema 3 contract")
    if (
        snapshot.get("requested_backend") != contract.get("requested_backend")
        or snapshot.get("resolved_backend") != contract.get("resolved_backend")
    ):
        fail("snapshot backend mismatch")
    if "control_root" in snapshot and snapshot.get("control_root") != contract.get("control_root"):
        fail("snapshot backend mismatch")
