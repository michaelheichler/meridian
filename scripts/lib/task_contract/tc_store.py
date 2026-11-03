import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any

from tc_common import SCHEMA_2_KEYS, SCHEMA_3_KEYS, Expect, JsonMap, fail
from tc_validate import validate_contract


def contract_path(root: Path, contract_id: str, control_root: Any = None) -> Path:
    nested = control_root and control_root.name != ".meridian"
    registry = control_root / "contracts" / "tasks" if nested else (control_root or root / ".meridian") / ".contracts" / "tasks"
    return registry / f"{contract_id}.json"


def locate_contract_path(root: Path, contract_id: str) -> Path:
    active = contract_path(root, contract_id)
    if active.is_file():
        return active
    runs = root / ".temporary-agent-runfiles" / "runs"
    run_roots = sorted(runs.iterdir()) if runs.is_dir() else []
    candidates = (contract_path(root, contract_id, run_root) for run_root in run_roots)
    return next((item for item in candidates if item.is_file()), active)


def control_root_for_contract_path(path: Path, root: Path) -> Any:
    resolved = path.resolve()
    active_root = (root / ".meridian").resolve()
    if resolved.parent == active_root / ".contracts" / "tasks":
        return None
    return resolved.parent.parent.parent


def validate_contract_path(path: Path, root: Path) -> Path:
    resolved = path.resolve()
    valid = resolved.parent == (root / ".meridian" / ".contracts" / "tasks").resolve()
    temporary_parent = root / ".temporary-agent-runfiles" / "runs"
    if temporary_parent.is_dir():
        runs = [item for item in temporary_parent.iterdir() if item.is_dir()]
        valid = valid or any(resolved.parent == (item / "contracts" / "tasks").resolve() for item in runs)
    if not valid:
        fail("contract path is outside the protected registry")
    return resolved


def lock_timeout_seconds() -> float:
    try:
        timeout = min(1000, max(1, int(os.environ.get("TASK_CONTRACT_LOCK_TIMEOUT_MS", "250"))))
    except ValueError:
        timeout = 250
    return timeout / 1000


def try_acquire(lock_dir: Path) -> bool:
    try:
        lock_dir.mkdir()
        (lock_dir / "pid").write_text(str(os.getpid()))
    except FileExistsError:
        return False
    return True


def lock(root: Path, control_root: Any = None) -> Path:
    nested = control_root and control_root.name != ".meridian"
    contracts = (control_root or root / ".meridian") / ("contracts" if nested else ".contracts")
    tasks = contracts / "tasks"
    lock_dir = contracts / ".lock"
    if contracts.is_symlink():
        fail("refusing symlinked .contracts directory")
    if tasks.is_symlink():
        fail("refusing symlinked .contracts/tasks directory")
    contracts.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + lock_timeout_seconds()
    while not try_acquire(lock_dir):
        if time.monotonic() >= deadline:
            fail("timed out acquiring contract lock")
        time.sleep(0.01)
    return lock_dir


def unlock(lock_dir: Path) -> None:
    try:
        (lock_dir / "pid").unlink(missing_ok=True)
        lock_dir.rmdir()
    except OSError:
        pass


def atomic(path: Path, contract: JsonMap) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(contract, sort_keys=True, indent=2) + "\n"
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".tmp.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def load(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        fail("invalid contract")


def immutable_equal(left: JsonMap, right: JsonMap) -> bool:
    ignored = {"state", "contract_digest"}
    keys = SCHEMA_2_KEYS if left.get("schema_version") == 2 else SCHEMA_3_KEYS
    return all(left.get(key) == right.get(key) for key in keys - ignored)


def check_existing(path: Path, root: Path, contract: JsonMap) -> None:
    existing = load(path)
    validate_contract(existing, root, Expect(contract["contract_id"]))
    if not immutable_equal(existing, contract):
        fail("duplicate contract")


def create_or_reopen(root: Path, contract: JsonMap) -> None:
    validate_contract(contract, root)
    control_root = Path(contract["control_root"]) if contract.get("schema_version") == 3 else None
    path = contract_path(root, contract["contract_id"], control_root)
    held = lock(root, control_root)
    try:
        if path.exists():
            check_existing(path, root, contract)
        else:
            atomic(path, contract)
        print(path)
    finally:
        unlock(held)
