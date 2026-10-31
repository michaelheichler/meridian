import re
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree as ET

from tc_build import AllowanceSpec, build_allowances, new_contract, plan_schema3_fields, schema3_plan_requested
from tc_common import JsonMap, Team, fail, safe_id, safe_path, safe_token, sha256_text, with_digest
from tc_roles import configured_team, default_team_mode

PlanParts = tuple[str, str, dict[str, str], list[str]]


def task_records(text: str) -> list[str]:
    if len(re.findall(r"<tasks\b", text)) != 1 or len(re.findall(r"</tasks>", text)) != 1:
        fail("duplicate tasks blocks")
    block = re.search(r"<tasks>(.*?)</tasks>", text, re.S)
    if not block or re.search(r"<tasks>|</tasks>", block.group(1)):
        fail("malformed PLAN task structure")
    records = re.findall(r"<task\b[^>]*>(.*?)</task>", block.group(1), re.S)
    if not records or len(records) != len(re.findall(r"<task\b", block.group(1))):
        fail("malformed PLAN task structure")
    return records


def task_values(body: str) -> dict[str, str]:
    try:
        node = ET.fromstring("<task>" + body + "</task>")
    except ET.ParseError:
        fail("malformed PLAN task structure")
    return {child.tag: (child.text or "").strip() for child in node}


def select_task(records: list[str], requested: str) -> dict[str, str]:
    selected = None
    for values in map(task_values, records):
        if values.get("name") != requested:
            continue
        if selected is not None:
            fail("duplicate task name")
        selected = values
    if selected is None:
        fail("unknown task")
    return selected


def parse_plan(path: Path, requested: str) -> PlanParts:
    try:
        text = path.read_text()
    except OSError:
        fail("PLAN is not readable")
    phase_match = re.search(r"(?m)^phase:\s*([0-9]+)\s*$", text)
    if not phase_match:
        fail("malformed PLAN: missing phase")
    phase = f"{int(phase_match.group(1)):02d}"
    selected = select_task(task_records(text), requested)
    required = ("name", "action", "verify", "done", "strategy")
    if any(not selected.get(key) for key in required):
        fail("malformed PLAN task: required field missing")
    files = [item.strip() for item in re.split(r"[\n,]", selected.get("files", "")) if item.strip()]
    if not files:
        fail("malformed PLAN task: files is required")
    for item in files:
        safe_path(item)
    return text, phase, selected, files


@dataclass(frozen=True)
class PlanRequest:
    path: Path
    root: Path
    task_name: str
    options: JsonMap


def plan_contract(request: PlanRequest) -> JsonMap:
    path, root, task_name, options = request.path, request.root, request.task_name, request.options
    text, phase, selected, plan_files = parse_plan(path, task_name)
    role = options["role"] or selected.get("role", "")
    if not role:
        fail("task role is required; pass --role ROLE")
    team = options["team"] or default_team_mode(role)
    group = safe_token(options["group"] or "task", "group")
    job = options["job"] or selected["action"]
    roles = configured_team(role, team)
    primary_paths = options["write_allowances"] or plan_files
    spec = AllowanceSpec(Team(roles, role), primary_paths, options["role_write_allowances"], plan_files)
    allowances, files = build_allowances(spec)
    suffix = [] if group == "task" else [group]
    core = {key: selected[key] for key in ("action", "verify", "done", "strategy")}
    core.update({
        "contract_id": safe_id(phase, path.stem, task_name, *suffix), "source_kind": "plan",
        "source_path": str(path), "source_sha256": sha256_text(text), "command_name": "build",
        "phase": phase, "task_name": task_name, "group": group, "team": team, "role": role,
        "roles": roles, "plan_files": plan_files, "files": files,
        "allowances": allowances, "job": job,
    })
    contract = new_contract(root, core)
    if schema3_plan_requested(options):
        contract.update(plan_schema3_fields(options, root, allowances))
    return with_digest(contract)
