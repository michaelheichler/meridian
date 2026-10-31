import json
import sys
from pathlib import Path
from typing import Any

from tc_build import assert_contract_matches_snapshot
from tc_command import command_contract
from tc_common import LEGAL, STATES, USAGE, canonical_root, digest_contract, fail, safe_token
from tc_options import parse_options
from tc_plan import plan_contract
from tc_store import (
    atomic, control_root_for_contract_path, create_or_reopen, load,
    locate_contract_path, lock, unlock, validate_contract_path,
)
from tc_validate import validate_contract


def finish_issue(root: Path, contract: dict[str, Any], options: dict[str, Any]) -> None:
    if options["assert_snapshot"]:
        assert_contract_matches_snapshot(options["assert_snapshot"], contract)
    create_or_reopen(root, contract)


def run_open(argv: list[str]) -> None:
    if len(argv) < 5:
        fail(USAGE)
    root = canonical_root(argv[3])
    plan = Path(argv[2]).resolve()
    try:
        plan.relative_to(root)
    except ValueError:
        fail("PLAN escapes project root")
    options = parse_options(argv[5:])
    finish_issue(root, plan_contract(plan, root, argv[4], options), options)


def run_issue(argv: list[str]) -> None:
    if len(argv) < 5:
        fail(USAGE)
    root = canonical_root(argv[2])
    options = parse_options(argv[4:], require_command=True)
    finish_issue(root, command_contract(root, argv[3], options), options)


def run_verify(argv: list[str]) -> None:
    if len(argv) not in (4, 6) or (len(argv) == 6 and argv[4] != "--job"):
        fail(USAGE)
    root = canonical_root(argv[3])
    path = validate_contract_path(Path(argv[2]), root)
    contract = load(path)
    validate_contract(contract, root, path.stem, argv[5] if len(argv) == 6 else None)
    print(json.dumps(contract, sort_keys=True, indent=2))


def transition(contract: dict[str, Any], new_state: str, path: Path) -> None:
    if new_state not in STATES:
        fail("invalid state")
    if new_state not in LEGAL.get(contract["state"], set()):
        fail("illegal state transition")
    contract["state"] = new_state
    contract["contract_digest"] = digest_contract(contract)
    atomic(path, contract)


def run_read_or_state(argv: list[str]) -> None:
    command = argv[1]
    if (command == "read" and len(argv) != 4) or (command == "state" and len(argv) != 5):
        fail(USAGE)
    root = canonical_root(argv[2])
    contract_id = safe_token(argv[3], "task id")
    path = locate_contract_path(root, contract_id)
    if not path.is_file():
        fail("unknown contract")
    held = lock(root, control_root_for_contract_path(path, root))
    try:
        contract = load(path)
        validate_contract(contract, root, contract_id)
        if command == "state":
            transition(contract, argv[4], path)
        print(json.dumps(contract, sort_keys=True, indent=2))
    finally:
        unlock(held)


def main() -> None:
    argv = sys.argv
    if len(argv) < 2:
        fail(USAGE)
    handlers = {"open": run_open, "issue": run_issue, "verify": run_verify,
                "read": run_read_or_state, "state": run_read_or_state}
    handler = handlers.get(argv[1])
    if handler is None:
        fail(USAGE)
    handler(argv)


if __name__ == "__main__":
    main()
