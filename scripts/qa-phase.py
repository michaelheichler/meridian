from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import NamedTuple

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS.parent / "hooks"))
from qa_command import CLAUDE_QA_AGENT, valid_arguments


OPEN_STATES = frozenset({"dispatched", "running"})
SKIPPABLE_PROMOTE_STATUSES = frozenset({"no_state_file", "no_todos_section"})
CAPABILITY_CATALOG = "claude-capabilities.json"
DEFAULT_STALE_RUNNING_MINUTES = 60


class QaError(RuntimeError):
    pass


class OpenContract(NamedTuple):
    contract_id: str
    state: str
    action: str
    age_minutes: int


class Phase(NamedTuple):
    root: Path
    number: str
    directory: Path
    verification: Path
    plans: list[Path]
    summaries: list[Path]


def run_command(root: Path, command: list[str], source: str | None = None) -> str:
    environment = dict(os.environ)
    for name in ("BASH_ENV", "ENV", "PYTHONHOME", "PYTHONPATH", "GIT_DIR", "GIT_WORK_TREE",
                 "QA_REMEDIATION_OUTPUT_PHASE_DIR"):
        environment.pop(name, None)
    result = subprocess.run(
        command, cwd=root, env=environment, input=source or "",
        text=True, capture_output=True, timeout=90, check=False,
    )
    if result.returncode:
        raise QaError(result.stderr.strip() or result.stdout.strip() or f"{Path(command[0]).name} failed")
    return result.stdout.strip()


def helper(root: Path, name: str, *args: str | Path, source: str | None = None) -> str:
    return run_command(root, ["/bin/bash", str(SCRIPTS / name), *map(str, args)], source)


def require_file(path: Path, *, optional: bool = False) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        if not optional:
            raise QaError(f"Missing {path}")
        return
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise QaError(f"Expected a regular file without aliases at {path}")


def resolve_phase(root: Path, number: str) -> Phase:
    number = f"{int(number):02d}"
    directory = root / ".meridian" / "phases"
    if not directory.is_dir() or directory.resolve() != directory:
        raise QaError("Run phase QA from a project root with a local .meridian/phases directory.")
    matches = [
        path for path in directory.iterdir()
        if path.is_dir() and re.match(rf"^{number}(?:-|$)", path.name)
    ]
    if len(matches) != 1 or matches[0].is_symlink():
        raise QaError(f"Expected one local phase directory for {number}.")
    phase = matches[0]
    plans = sorted(path for path in phase.glob("*PLAN.md") if path.name == "PLAN.md" or path.name.endswith("-PLAN.md"))
    summaries = sorted(
        path for path in phase.glob("*SUMMARY.md")
        if path.name == "SUMMARY.md" or path.name.endswith("-SUMMARY.md")
    )
    if not plans or not summaries:
        raise QaError(f"Phase {number} needs a plan and completed summary before QA.")
    for path in (*plans, *summaries):
        require_file(path)
    remediation = phase / "remediation"
    if remediation.is_symlink() or (remediation / "qa").is_symlink():
        raise QaError("QA remediation must be stored in a local phase directory.")
    if (remediation / "qa" / ".qa-remediation-stage").exists():
        raise QaError("This phase has active QA remediation. Use Meridian transit for that run.")
    verification = phase / f"{number}-VERIFICATION.md"
    for path in (verification, phase / "known-issues.json", root / ".meridian" / "STATE.md"):
        require_file(path, optional=True)
    return Phase(root, number, phase, verification, plans, summaries)


def context(phase: Phase) -> dict:
    return {
        "phase": phase.number,
        "phase_dir": str(phase.directory),
        "plans": list(map(str, phase.plans)),
        "summaries": list(map(str, phase.summaries)),
        "known_issues": str(phase.directory / "known-issues.json"),
        "task_contracts_present": (phase.root / ".meridian" / ".contracts" / "tasks").is_dir(),
        "verification": str(phase.verification),
    }


def git_head(phase: Phase) -> str:
    return run_command(phase.root, ["git", "rev-parse", "--verify", "HEAD"])


def transition(phase: Phase, contract_id: str, state: str) -> None:
    helper(phase.root, "task-contract.sh", "state", phase.root, contract_id, state)


def start(phase: Phase, tier: str, host: str) -> dict:
    if not phase.verification.exists():
        helper(phase.root, "track-known-issues.sh", "sync-summaries", phase.directory)
    catalog_stale = host == "claude" and not refresh_capabilities(phase)
    agent = claude_agent(phase) if host == "claude" else {"agent_type": "meridian-qa"}
    job = f"Verify phase {phase.number} tier {tier} at {git_head(phase)}"
    contract_id = reusable_contract(phase, job) or issue_contract(phase, job)
    return {**context(phase), "contract_id": contract_id, "agent": agent, "catalog_stale": catalog_stale}


def issue_contract(phase: Phase, job: str) -> str:
    task = f"qa-{phase.number}-{uuid.uuid4().hex[:12]}"
    contract = Path(helper(
        phase.root, "task-contract.sh", "issue", phase.root, task,
        "--command", "qa", "--role", "qa", "--team", "solo", "--group", "phase", "--job", job,
    ))
    transition(phase, contract.stem, "dispatched")
    return contract.stem


def reusable_contract(phase: Phase, job: str) -> str | None:
    contracts = open_contracts(phase)
    stale_limit = stale_running_minutes()
    refuse_live_workers(contracts, stale_limit)
    reusable = None
    for contract in contracts:
        if contract.state == "running":
            retire_contract(phase, contract.contract_id, f"it was stale for {contract.age_minutes} minutes")
        elif reusable is None and contract.action == job:
            reusable = contract.contract_id
        else:
            retire_contract(phase, contract.contract_id, "a new run started")
    return reusable


def refuse_live_workers(contracts: list[OpenContract], stale_limit: int) -> None:
    for contract in contracts:
        if contract.state == "running" and contract.age_minutes < stale_limit:
            raise QaError(
                f"QA contract {contract.contract_id} has been running for {contract.age_minutes} minutes. "
                f"Publish its verdict, or run start again after {stale_limit} minutes to retire it."
            )


def stale_running_minutes() -> int:
    try:
        return max(0, int(os.environ.get("MERIDIAN_QA_STALE_MINUTES", DEFAULT_STALE_RUNNING_MINUTES)))
    except ValueError:
        return DEFAULT_STALE_RUNNING_MINUTES


def retire_contract(phase: Phase, contract_id: str, reason: str) -> None:
    if read_contract(phase, contract_id).get("state") == "blocked":
        return
    transition(phase, contract_id, "blocked")
    sys.stderr.write(f"Meridian QA: moved contract {contract_id} to blocked because {reason}.\n")


def read_contract(phase: Phase, contract_id: str) -> dict:
    return json.loads(helper(phase.root, "task-contract.sh", "read", phase.root, contract_id))


def open_contracts(phase: Phase) -> list[OpenContract]:
    registry = phase.root / ".meridian" / ".contracts" / "tasks"
    if not registry.is_dir():
        return []
    found = []
    for path in sorted(registry.glob(f"cmd-qa-qa-{phase.number}-*-phase.json")):
        contract = read_contract(phase, path.stem)
        if contract.get("state") in OPEN_STATES:
            age_minutes = int((time.time() - path.stat().st_mtime) // 60)
            found.append(OpenContract(path.stem, contract["state"], contract.get("action", ""), age_minutes))
    return found


def claude_agent(phase: Phase) -> dict:
    planning = phase.root / ".meridian"
    route = json.loads(helper(phase.root, "meridian-routing.sh", "resolve", planning, "qa"))
    catalog = json.loads((planning / CAPABILITY_CATALOG).read_text(encoding="utf-8"))
    model = catalog["agent_model_ids"].get(route["model"])
    if not model:
        raise QaError("Meridian could not map the QA model to a Claude Agent selector.")
    return {"subagent_type": CLAUDE_QA_AGENT, "model": model}


def refresh_capabilities(phase: Phase) -> bool:
    planning = phase.root / ".meridian"
    try:
        helper(phase.root, "meridian-model", "refresh", planning)
        return True
    except QaError as exc:
        if not (planning / CAPABILITY_CATALOG).is_file():
            raise QaError(
                f"The Claude capability refresh failed and no saved {CAPABILITY_CATALOG} exists. {exc}"
            ) from exc
        sys.stderr.write(f"Meridian QA: capability refresh failed, so QA uses the saved catalog. {exc}\n")
        return False


def publish(phase: Phase, contract_id: str, verdict: dict) -> dict:
    if not contract_id.startswith(f"cmd-qa-qa-{phase.number}-"):
        raise QaError("The QA contract does not belong to this phase.")
    contract = json.loads(helper(phase.root, "task-contract.sh", "read", phase.root, contract_id))
    payload = verdict.get("payload")
    if verdict.get("type") != "qa_verdict" or verdict.get("author_role") != "qa" or not isinstance(payload, dict):
        raise QaError("A structured QA worker verdict is required.")
    if not payload.get("plans_verified"):
        raise QaError("The QA worker must supply payload.plans_verified with every canonical plan ID.")
    if contract.get("role") != "qa" or contract.get("command_name") != "qa":
        raise QaError("The contract is not a Meridian QA contract.")
    job = f"Verify phase {phase.number} tier {payload.get('tier')} at {git_head(phase)}"
    if contract.get("action") != job or str(verdict.get("phase")) not in {phase.number, str(int(phase.number))}:
        raise QaError("The verdict must match the issued phase, tier, and commit.")
    state = contract["state"]
    if state == "dispatched":
        transition(phase, contract_id, "running")
        state = "running"
    if state == "running":
        transition(phase, contract_id, "awaiting_review")
    elif state != "awaiting_review":
        raise QaError(f"The QA contract is already {state}.")
    source = json.dumps({**verdict, "phase": phase.number, "payload": {**payload, "phase": phase.number}})
    try:
        helper(phase.root, "write-verification.sh", phase.verification, source=source)
        helper(phase.root, "track-known-issues.sh", "sync-verification", phase.directory, phase.verification)
        promote_known_issues(phase)
        result = helper(phase.root, "qa-result-gate.sh", phase.directory)
        match = re.search(r"^qa_gate_routing=([A-Z_]+)$", result, re.MULTILINE)
        if match is None:
            raise QaError("The deterministic gate returned no routing verdict.")
        routing = match.group(1)
        if routing == "REMEDIATION_REQUIRED":
            helper(phase.root, "qa-remediation-state.sh", "init", phase.directory)
    except (QaError, OSError, subprocess.SubprocessError) as publish_error:
        block_after_failure(phase, contract_id, publish_error)
        raise
    transition(phase, contract_id, "verified" if routing == "PROCEED_TO_UAT" else "blocked")
    return {"verification": str(phase.verification), "contract_id": contract_id, "routing": routing}


def block_after_failure(phase: Phase, contract_id: str, cause: Exception) -> None:
    try:
        transition(phase, contract_id, "blocked")
    except (QaError, OSError, subprocess.SubprocessError) as transition_error:
        raise QaError(
            f"{cause} The contract {contract_id} also failed to move to blocked. {transition_error}"
        ) from cause


def promote_known_issues(phase: Phase) -> None:
    try:
        helper(phase.root, "track-known-issues.sh", "promote-todos", phase.directory)
    except QaError as exc:
        if promote_status(str(exc)) not in SKIPPABLE_PROMOTE_STATUSES:
            raise


def promote_status(output: str) -> str | None:
    statuses = re.findall(r"^promote_status=(\w+)$", output, re.MULTILINE)
    return statuses[-1] if statuses else None


def main(args: list[str]) -> int:
    if not valid_arguments(args):
        sys.stderr.write(
            "Use inspect PHASE, route PHASE OWNERS_JSON, start PHASE TIER HOST, "
            "or publish PHASE CONTRACT VERDICT_JSON.\n"
        )
        return 2
    try:
        phase = resolve_phase(Path.cwd().resolve(), args[1])
        if args[0] == "start":
            result = start(phase, args[2], args[3])
        elif args[0] == "publish":
            result = publish(phase, args[2], json.loads(args[3]))
        elif args[0] == "route":
            result = json.loads(helper(
                phase.root, "qa-routing.sh", phase.root / ".meridian", source=args[2],
            ))
        else:
            result = context(phase)
    except (QaError, OSError, ValueError, subprocess.SubprocessError) as exc:
        sys.stderr.write(f"Meridian QA: {exc}\n")
        return 1
    sys.stdout.write(json.dumps(result) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
