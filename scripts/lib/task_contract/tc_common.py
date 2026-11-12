import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn

JsonMap = dict[str, Any]
AllowMap = dict[str, list[str]]
CapMap = dict[str, list[dict[str, str]]]
AllowResult = tuple[AllowMap, list[str]]


@dataclass(frozen=True)
class Team:
    roles: list[str]
    primary: str


@dataclass(frozen=True)
class Expect:
    contract_id: Any = None
    job: Any = None

USAGE = (
    "Usage: task-contract.sh "
    "<open PLAN.md project-root task-name [options]|"
    "issue project-root task-name --command NAME --role ROLE --team solo|pair|trio --job TEXT [options]|"
    "verify contract-path project-root [--job TEXT]|"
    "read project-root task-id|state project-root task-id STATE>"
)
LEGAL = {
    "planned": {"dispatched", "cancelled"},
    "dispatched": {"running", "cancelled", "blocked"},
    "running": {"awaiting_review", "blocked", "cancelled"},
    "awaiting_review": {"verified", "blocked"},
    "blocked": {"dispatched", "cancelled"},
    "verified": set(),
    "cancelled": set(),
}
STATES = set(LEGAL)
RUNTIME_KINDS = {"native-team"}
COMMUNICATION_POLICIES = {"native-team", "critic-relay"}
EXECUTION_BACKENDS = {"in_process", "tmux", "workflow"}
SCHEMA_2_KEYS = {
    "contract_id", "schema_version", "created_by", "project_root",
    "source_kind", "source_path", "source_sha256", "command_name",
    "phase", "task_name", "task_identity", "group_name", "team_mode",
    "role", "roles", "test_dev", "plan_files", "files",
    "write_allowances", "allowances_by_role", "job_sha256", "action",
    "verify", "done", "strategy", "state", "contract_digest",
}
SCHEMA_3_KEYS = SCHEMA_2_KEYS | {
    "capabilities_by_role", "communication_policy", "control_root", "runtime_kind",
    "requested_backend", "resolved_backend"
}
SCHEMA_3_ONLY_KEYS = (
    "capabilities_by_role", "control_root", "runtime_kind",
    "communication_policy", "requested_backend", "resolved_backend",
)
PROTECTED_EXACT = {
    "config/subagent-critical-execution.txt",
    "config/destructive-commands.txt",
    "scripts/task-contract.sh",
    "scripts/agent-lifecycle.sh",
    ".meridian/.agent-manifest.json",
    ".meridian/.contracts",
    ".claude/agents",
}
PROTECTED_DIRS = (".git", ".temporary-agent-runfiles")
PROTECTED_PREFIXES = (".meridian/.contracts/", ".claude/agents/")
PROTECTED_SUFFIXES = ("credentials.json", "secrets.json", "service-account.json")


def fail(message: str) -> NoReturn:
    print("Error: " + message, file=sys.stderr)
    raise SystemExit(1)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def canonical_root(value: str) -> Path:
    root = Path(value).resolve()
    if not root.is_dir():
        fail("project root is unavailable")
    return root


def safe_token(value: Any, label: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value or "") or ".." in value:
        fail(f"invalid {label}")
    return value


def safe_path(value: Any) -> str:
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or "\n" in value
        or "\r" in value
        or any(part in ("", ".", "..") for part in value.split("/"))
    ):
        fail("files must be repo-relative paths")
    return value


def safe_capability_path(value: Any, kind: Any) -> str:
    if kind == "directory" and value == ".":
        return value
    if kind not in {"file", "directory"}:
        fail("capability kind must be file or directory")
    safe_path(value)
    return value


def resolve_control_root(value: str, root: Path) -> Path:
    script = Path(os.environ["TASK_CONTRACT_SCRIPT_DIR"]) / "lib" / "meridian-control-root.sh"
    if not script.is_file():
        fail("control root resolver is unavailable")
    try:
        result = subprocess.run(
            ["bash", "-c", '. "$1"; meridian_resolve_control_root "$2" "$3" "$4"',
             "meridian-control-root", str(script), value, str(root), str(root)],
            check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        fail("control root is unavailable or invalid")
    resolved = result.stdout.strip()
    if not resolved:
        fail("control root is unavailable or invalid")
    return Path(resolved)


def protected_worker_path(value: str) -> bool:
    if any(value == name or value.startswith(name + "/") for name in PROTECTED_DIRS):
        return True
    if value == ".env" or value.startswith(".env.") or "/.env" in value:
        return True
    if re.search(r"(^|/)[^/]+\.(pem|key|cert|p12|pfx)(\.[A-Za-z0-9]+)?$", value):
        return True
    if value.endswith(PROTECTED_SUFFIXES) or value in PROTECTED_EXACT:
        return True
    if value.startswith(PROTECTED_PREFIXES):
        return True
    return value.startswith("scripts/") and "guard" in Path(value).name


def safe_id(*parts: str) -> str:
    raw = "-".join(parts)
    result = re.sub(r"[^A-Za-z0-9._-]+", "-", raw).strip(".-")
    if not result or ".." in result:
        fail("invalid task name")
    return result


def digest_contract(contract: dict[str, Any]) -> str:
    immutable = {key: value for key, value in contract.items() if key not in ("contract_digest", "state")}
    canonical = json.dumps(immutable, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def with_digest(contract: dict[str, Any]) -> dict[str, Any]:
    contract["contract_digest"] = digest_contract(contract)
    return contract
