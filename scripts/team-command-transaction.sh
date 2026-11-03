#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/lib/meridian-control-root.sh"
. "$SCRIPT_DIR/lib/meridian-settings.sh"
. "$SCRIPT_DIR/lib/turn-value.sh"

SETTINGS_PATH="${MERIDIAN_SETTINGS_PATH:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"

fail() {
  printf 'team-command-transaction: %s\n' "$1" >&2
  exit 1
}

fail_diag() {
  local message="$1"
  if [ -n "${RUN_ROOT:-}" ] && [ -d "${RUN_ROOT:-}" ]; then
    printf '%s\n' "$(jq -cn --arg action "$ACTION" --arg message "$message" \
      '{event:"fail",action:$action,message:$message,at:(now | todate)}')" \
      >> "$RUN_ROOT/diagnostics.jsonl" 2>/dev/null || true
  fi
  fail "$message"
}

usage() {
  printf '%s\n' \
    'Usage: team-command-transaction.sh preflight --project-root PATH [--role ROLE ...] [--scope PATH ...] [--engineer ROLE] [--test-dev]' \
    '       team-command-transaction.sh propose --project-root PATH [--engineer ROLE] [--test-dev]' \
    '       team-command-transaction.sh prepare --project-root PATH --run-id ID --instruction TEXT [--role ROLE ...] [--scope PATH ...] [--engineer ROLE] [--test-dev]' \
    '       team-command-transaction.sh spawn-payload --project-root PATH --run-root PATH' \
    '       team-command-transaction.sh record-spawn --project-root PATH --run-root PATH --contract-id ID --teammate NAME' \
    '       team-command-transaction.sh task-payload --project-root PATH --run-root PATH' \
    '       team-command-transaction.sh record-task --project-root PATH --run-root PATH --contract-id ID --task-id ID' \
    '       team-command-transaction.sh fail --project-root PATH --run-root PATH [--event TEXT]' \
    '       team-command-transaction.sh complete --project-root PATH --run-root PATH [--event TEXT]' \
    '       team-command-transaction.sh summary --project-root PATH --run-root PATH' >&2
  exit 2
}

is_valid_role() {
  jq -e --arg role "$1" 'has($role)' "$ROLE_DEFAULTS_PATH" >/dev/null 2>&1
}

is_critic_role() {
  case "$1" in
    *critic) return 0 ;;
    *) return 1 ;;
  esac
}

is_valid_run_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

is_valid_record_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]
}

protected_scope_path() {
  local value="$1"
  case "$value" in
    .git|.git/*|.temporary-agent-runfiles|.temporary-agent-runfiles/*|.meridian|.meridian/*|.claude|.claude/*) return 0 ;;
    .env|.env.*|*/.env|*/.env.*) return 0 ;;
    *credentials.json|*secrets.json|*service-account.json) return 0 ;;
    *.pem|*.key|*.cert|*.p12|*.pfx) return 0 ;;
  esac
  return 1
}

require_file() {
  [ -f "$1" ] || fail "$2: $1"
}

ACTION="${1:-}"
[ -n "$ACTION" ] || usage
case "$ACTION" in
  preflight|propose|prepare|spawn-payload|record-spawn|task-payload|record-task|fail|complete|summary) ;;
  *) usage ;;
esac
shift

PROJECT_ROOT_ARG=""
RUN_ROOT_ARG=""
RUN_ID=""
INSTRUCTION=""
ENGINEER_ARG=""
WANT_TEST_DEV=false
CONTRACT_ID_ARG=""
TEAMMATE_ARG=""
TASK_ID_ARG=""
EVENT_TEXT=""
ROLES=()
SCOPES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-root)
      [ "$#" -ge 2 ] || fail '--project-root requires a path'
      PROJECT_ROOT_ARG="$2"
      shift 2
      ;;
    --run-root)
      [ "$#" -ge 2 ] || fail '--run-root requires a path'
      RUN_ROOT_ARG="$2"
      shift 2
      ;;
    --run-id)
      [ "$#" -ge 2 ] || fail '--run-id requires a value'
      RUN_ID="$2"
      shift 2
      ;;
    --instruction)
      [ "$#" -ge 2 ] || fail '--instruction requires text'
      INSTRUCTION="$2"
      shift 2
      ;;
    --role)
      [ "$#" -ge 2 ] || fail '--role requires a value'
      ROLES+=("$2")
      shift 2
      ;;
    --scope)
      [ "$#" -ge 2 ] || fail '--scope requires a path'
      SCOPES+=("$2")
      shift 2
      ;;
    --engineer)
      [ "$#" -ge 2 ] || fail '--engineer requires a role'
      ENGINEER_ARG="$2"
      shift 2
      ;;
    --test-dev)
      WANT_TEST_DEV=true
      shift
      ;;
    --contract-id)
      [ "$#" -ge 2 ] || fail '--contract-id requires a value'
      CONTRACT_ID_ARG="$2"
      shift 2
      ;;
    --teammate)
      [ "$#" -ge 2 ] || fail '--teammate requires a name'
      TEAMMATE_ARG="$2"
      shift 2
      ;;
    --task-id)
      [ "$#" -ge 2 ] || fail '--task-id requires a value'
      TASK_ID_ARG="$2"
      shift 2
      ;;
    --event)
      [ "$#" -ge 2 ] || fail '--event requires text'
      EVENT_TEXT="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail 'jq is required'
ROLE_DEFAULTS_PATH="$SCRIPT_DIR/../templates/agent-roles/defaults.json"
require_file "$ROLE_DEFAULTS_PATH" 'role defaults not found'

PROJECT_ROOT=""
RUN_ROOT=""
RESOLVED_SCOPES='[]'
ACTIVE_CONTROL_ROOT=""
CONTROL_ROOT_KIND="temporary-run"
AGENT_TEAMS_STATUS='{}'
CONTRACT_REQUESTED_BACKEND=""
CONTRACT_RESOLVED_BACKEND=""

canonical_project_root() {
  local candidate="$1"
  [ -n "$candidate" ] || fail '--project-root is required'
  [ -d "$candidate" ] || fail "project root does not exist: $candidate"
  [ ! -L "$candidate" ] || fail 'project root must not be a symbolic link'
  (CDPATH='' cd -P -- "$candidate" && pwd -P) || fail "project root is not readable: $candidate"
}

resolve_run_root() {
  [ -n "$RUN_ROOT_ARG" ] || fail '--run-root is required'
  local canonical
  canonical=$(CDPATH='' cd -P -- "$RUN_ROOT_ARG" 2>/dev/null && pwd -P) || fail "run root is not readable: $RUN_ROOT_ARG"
  [ "$(dirname "$canonical")" = "$PROJECT_ROOT/.temporary-agent-runfiles/runs" ] \
    || fail 'run root is outside the project temporary run directory'
  RUN_ROOT="$canonical"
}

resolve_scopes() {
  local scope_json scope
  local -a scope_args=()
  for scope in ${SCOPES[@]+"${SCOPES[@]}"}; do
    scope_args+=(--scope "$scope")
  done
  scope_json=$(bash "$SCRIPT_DIR/team-run-state.sh" resolve-scopes \
    --project-root "$PROJECT_ROOT" ${scope_args[@]+"${scope_args[@]}"}) \
    || fail 'scope resolution failed'
  RESOLVED_SCOPES=$(jq -ce '.scopes' <<< "$scope_json") || fail 'scope resolution returned invalid JSON'
}

reject_protected_scopes() {
  local scope
  while IFS= read -r scope; do
    [ -n "$scope" ] || continue
    if protected_scope_path "$scope"; then
      fail "scope is protected and cannot be granted to a generated worker: $scope"
    fi
  done < <(jq -r '.[]' <<< "$RESOLVED_SCOPES")
}

read_agent_teams_status() {
  local project_root="$1" out_status="$2" status_json
  status_json=$(bash "$SCRIPT_DIR/meridian-config.sh" agent-teams-status --project-root "$project_root") \
    || fail 'could not read agent teams status'
  printf -v "$out_status" '%s' "$status_json"
}

require_run_contract() {
  local contract
  [ -f "$RUN_ROOT/run.json" ] || fail_diag "run state is missing: $RUN_ROOT/run.json"
  EXPECTED_CONTRACT=$(jq -r '.contract_id // empty' "$RUN_ROOT/contract.json" 2>/dev/null) || true
  [ -n "$EXPECTED_CONTRACT" ] || fail_diag 'contract record is missing or unreadable'
  contract=$(bash "$SCRIPT_DIR/task-contract.sh" read "$PROJECT_ROOT" "$EXPECTED_CONTRACT" 2>/dev/null) \
    || fail_diag 'contract is missing, stale, or tampered'
  CONTRACT_REQUESTED_BACKEND=$(jq -r '.requested_backend // empty' <<< "$contract")
  CONTRACT_RESOLVED_BACKEND=$(jq -r '.resolved_backend // empty' <<< "$contract")
  case "$CONTRACT_REQUESTED_BACKEND" in in_process|tmux|workflow) ;; *) fail_diag 'contract backend metadata is invalid' ;; esac
  case "$CONTRACT_RESOLVED_BACKEND" in in_process|tmux|workflow) ;; *) fail_diag 'contract backend metadata is invalid' ;; esac
  [ "$CONTRACT_REQUESTED_BACKEND" = "$CONTRACT_RESOLVED_BACKEND" ] || fail_diag 'contract backend metadata is invalid'
  jq -e --arg contract "$EXPECTED_CONTRACT" --arg requested "$CONTRACT_REQUESTED_BACKEND" --arg resolved "$CONTRACT_RESOLVED_BACKEND" '
    .schema_version == 3 and .contract_id == $contract
    and .requested_backend == $requested and .resolved_backend == $resolved
  ' "$RUN_ROOT/contract.json" >/dev/null || fail_diag 'contract backend metadata does not match the contract'
  jq -e --arg requested "$CONTRACT_REQUESTED_BACKEND" --arg resolved "$CONTRACT_RESOLVED_BACKEND" '
    .requested_backend == $requested and .resolved_backend == $resolved
  ' "$RUN_ROOT/run.json" >/dev/null || fail_diag 'run backend metadata does not match the contract'
}

. "$SCRIPT_DIR/lib/team-command-transaction-roster.sh"
. "$SCRIPT_DIR/lib/team-command-transaction-routing.sh"
. "$SCRIPT_DIR/lib/team-command-transaction-run.sh"
. "$SCRIPT_DIR/lib/team-command-transaction-prepare.sh"

case "$ACTION" in
  preflight)
    PROJECT_ROOT=$(canonical_project_root "$PROJECT_ROOT_ARG")
    require_file "$SCRIPT_DIR/cleanup-temporary-agent-runfiles.sh" 'cleanup helper not found'
    require_file "$SCRIPT_DIR/team-run-state.sh" 'run state helper not found'
    require_file "$SCRIPT_DIR/team-context-index.sh" 'context index helper not found'
    require_file "$SCRIPT_DIR/task-contract.sh" 'contract helper not found'
    require_file "$SCRIPT_DIR/agent-generator.sh" 'generator helper not found'
    require_file "$SCRIPT_DIR/meridian-config.sh" 'config helper not found'
    require_file "$SCRIPT_DIR/meridian-routing.sh" 'routing helper not found'
    resolve_scopes
    reject_protected_scopes
    resolve_active_control_root
    resolve_roster ROSTER_ENGINEER ROSTER_CRITIC ROSTER_TEST_DEV TEAM_MODE ROSTER_ROLES_JSON
    resolve_routing "$ROSTER_ENGINEER" ROUTING_RECORD
    read_agent_teams_status "$PROJECT_ROOT" AGENT_TEAMS_STATUS
    jq -n \
      --arg project_root "$PROJECT_ROOT" \
      --argjson scopes "$RESOLVED_SCOPES" \
      --argjson roles "$ROSTER_ROLES_JSON" \
      --arg engineer "$ROSTER_ENGINEER" \
      --arg team_mode "$TEAM_MODE" \
      --arg control_root_kind "$CONTROL_ROOT_KIND" \
      --arg active_control_root "$ACTIVE_CONTROL_ROOT" \
      --argjson routing "$ROUTING_RECORD" \
      --arg settings_path "$SETTINGS_PATH" \
      --argjson agent_teams_status "$AGENT_TEAMS_STATUS" \
      '{schema_version:1,project_root:$project_root,scopes:$scopes,roles:$roles,engineer:$engineer,
        team_mode:$team_mode,
        control_root_kind:$control_root_kind,active_control_root:$active_control_root,
        routing:{mode:$routing.mode,profile:$routing.profile,model:$routing.model,reasoning:$routing.reasoning,
          max_turns:$routing.max_turns},
        agent_teams:{enabled:($agent_teams_status.enabled == true),settings_path:$settings_path,
          status:$agent_teams_status},
        side_effects:false}'
    ;;

  propose)
    PROJECT_ROOT=$(canonical_project_root "$PROJECT_ROOT_ARG")
    resolve_roster ROSTER_ENGINEER ROSTER_CRITIC ROSTER_TEST_DEV TEAM_MODE ROSTER_ROLES_JSON
    jq -n --argjson roles "$ROSTER_ROLES_JSON" --arg engineer "$ROSTER_ENGINEER" \
      --arg critic "$ROSTER_CRITIC" --arg team_mode "$TEAM_MODE" \
      --argjson test_dev "$ROSTER_TEST_DEV" \
      '{schema_version:1,roles:$roles,engineer:$engineer,critic:$critic,team_mode:$team_mode,test_dev:$test_dev}'
    ;;

  prepare)
    action_prepare
    ;;

  spawn-payload)
    PROJECT_ROOT=$(canonical_project_root "$PROJECT_ROOT_ARG")
    resolve_run_root
    require_run_roster ROSTER_JSON MANIFEST_PATH
    PAYLOADS='[]'
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      jq -e --arg name "$name" --arg contract "$EXPECTED_CONTRACT" '
        (.agents[$name] | type == "object")
        and (.agents[$name].contract_id == $contract)
        and (.agents[$name].state == "registered")
        and (.agents[$name].runtime_kind == "native-team")
      ' "$MANIFEST_PATH" >/dev/null || fail_diag "teammate '$name' is not spawn-ready for contract $EXPECTED_CONTRACT"
      PAYLOADS=$(jq -c --arg name "$name" '. + [{subagent_type:$name,name:$name}]' <<< "$PAYLOADS")
    done < <(jq -r '.[]' <<< "$ROSTER_JSON")
    jq -n --arg contract_id "$EXPECTED_CONTRACT" --argjson payloads "$PAYLOADS" \
      --argjson roster "$ROSTER_JSON" \
      '{schema_version:1,contract_id:$contract_id,roster:$roster,agent_payloads:$payloads,next_action:"task-payload"}'
    ;;

  record-spawn)
    PROJECT_ROOT=$(canonical_project_root "$PROJECT_ROOT_ARG")
    resolve_run_root
    [ -n "$CONTRACT_ID_ARG" ] || fail '--contract-id is required'
    is_valid_record_id "$CONTRACT_ID_ARG" || fail 'contract id is invalid'
    [ -n "$TEAMMATE_ARG" ] || fail '--teammate is required'
    is_valid_record_id "$TEAMMATE_ARG" || fail 'teammate name is invalid'
    require_run_roster ROSTER_JSON MANIFEST_PATH
    [ "$CONTRACT_ID_ARG" = "$EXPECTED_CONTRACT" ] || fail_diag "contract id mismatch: expected $EXPECTED_CONTRACT"
    jq -e --arg name "$TEAMMATE_ARG" '.agents[$name] | type == "object"' "$MANIFEST_PATH" >/dev/null \
      || fail_diag "teammate is not registered in the run manifest: $TEAMMATE_ARG"
    jq -e --arg name "$TEAMMATE_ARG" '.agents[$name].state == "running"' "$MANIFEST_PATH" >/dev/null \
      || fail_diag "teammate '$TEAMMATE_ARG' is not running in the manifest; the spawn guard must claim it first"
    SPAWN_RECORD=$(jq -c --argjson roster "$ROSTER_JSON" --arg teammate "$TEAMMATE_ARG" '
      .records = (.records // {})
      | .records["spawn:\($teammate)"] = {kind:"spawn",id:$teammate,status:"recorded",updated_at:(now | todate)}
      | (([.records | to_entries[] | select(.key | startswith("spawn:")) | .value.id]) | unique) as $recorded
      | .spawned = $recorded
      | .spawn_complete = (($roster - $recorded) | length == 0)
      | .updated_at = (now | todate)
    ' "$RUN_ROOT/run.json") || fail_diag 'run state is unreadable'
    printf '%s\n' "$SPAWN_RECORD" > "$RUN_ROOT/run.json"
    printf '%s\n' "$(jq -cn --arg teammate "$TEAMMATE_ARG" --arg contract "$CONTRACT_ID_ARG" \
      '{event:"record-spawn",teammate:$teammate,contract_id:$contract,at:(now | todate)}')" \
      >> "$RUN_ROOT/diagnostics.jsonl" || fail_diag 'diagnostics append failed'
    SPAWN_COMPLETE=$(jq -r '.spawn_complete' <<< "$SPAWN_RECORD")
    SPAWNED_JSON=$(jq -c '.spawned // []' <<< "$SPAWN_RECORD")
    jq -n --arg teammate "$TEAMMATE_ARG" --arg contract_id "$CONTRACT_ID_ARG" \
      --argjson spawned "$SPAWNED_JSON" --argjson roster "$ROSTER_JSON" \
      --argjson complete "$SPAWN_COMPLETE" \
      '{schema_version:1,teammate:$teammate,contract_id:$contract_id,recorded:true,
        spawned:$spawned,roster:$roster,spawn_complete:$complete}'
    ;;

  task-payload)
    PROJECT_ROOT=$(canonical_project_root "$PROJECT_ROOT_ARG")
    resolve_run_root
    require_run_roster ROSTER_JSON MANIFEST_PATH
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      jq -e --arg name "$name" --arg contract "$EXPECTED_CONTRACT" '
        (.agents[$name] | type == "object")
        and (.agents[$name].contract_id == $contract)
        and (.agents[$name].state == "running")
      ' "$MANIFEST_PATH" >/dev/null || fail_diag "teammate '$name' is not running in the manifest"
      jq -e --arg key "spawn:$name" '.records[$key].status == "recorded"' "$RUN_ROOT/run.json" >/dev/null \
        || fail_diag "spawn evidence is missing for teammate: $name"
    done < <(jq -r '.[]' <<< "$ROSTER_JSON")
    jq -n --arg contract_id "$EXPECTED_CONTRACT" --argjson roster "$ROSTER_JSON" \
      '{schema_version:1,task:{subject:$contract_id,description:$contract_id},
        contract_id:$contract_id,roster:$roster}'
    ;;

  record-task)
    PROJECT_ROOT=$(canonical_project_root "$PROJECT_ROOT_ARG")
    resolve_run_root
    [ -n "$CONTRACT_ID_ARG" ] || fail '--contract-id is required'
    is_valid_record_id "$CONTRACT_ID_ARG" || fail 'contract id is invalid'
    [ -n "$TASK_ID_ARG" ] || fail '--task-id is required'
    is_valid_record_id "$TASK_ID_ARG" || fail 'task id is invalid'
    require_run_roster ROSTER_JSON MANIFEST_PATH
    [ "$CONTRACT_ID_ARG" = "$EXPECTED_CONTRACT" ] || fail_diag "contract id mismatch: expected $EXPECTED_CONTRACT"
    jq -e --arg task "$TASK_ID_ARG" --arg contract "$CONTRACT_ID_ARG" \
      '.tasks[$task].contract_id == $contract' "$MANIFEST_PATH" >/dev/null \
      || fail_diag "native task is not bound to this contract: $TASK_ID_ARG"
    TASK_RECORD=$(jq -c --arg task "$TASK_ID_ARG" '
      .records = (.records // {})
      | .records["task:\($task)"] = {kind:"task",id:$task,status:"bound",updated_at:(now | todate)}
      | .updated_at = (now | todate)
    ' "$RUN_ROOT/run.json") || fail_diag 'run state is unreadable'
    printf '%s\n' "$TASK_RECORD" > "$RUN_ROOT/run.json"
    printf '%s\n' "$(jq -cn --arg task "$TASK_ID_ARG" --arg contract "$CONTRACT_ID_ARG" \
      '{event:"record-task",task_id:$task,contract_id:$contract,at:(now | todate)}')" \
      >> "$RUN_ROOT/diagnostics.jsonl" || fail_diag 'diagnostics append failed'
    jq -n --arg task_id "$TASK_ID_ARG" --arg contract_id "$CONTRACT_ID_ARG" \
      '{schema_version:1,task_id:$task_id,contract_id:$contract_id,recorded:true,contract_state:"dispatched"}'
    ;;

  fail)
    PROJECT_ROOT=$(canonical_project_root "$PROJECT_ROOT_ARG")
    resolve_run_root
    bash "$SCRIPT_DIR/team-run-state.sh" update --run-root "$RUN_ROOT" \
      --status failed ${EVENT_TEXT:+--event "$EVENT_TEXT"} >/dev/null \
      || fail_diag 'run state update failed'
    jq -n --arg run_root "$RUN_ROOT" --arg event "$EVENT_TEXT" \
      '{schema_version:1,run_root:$run_root,status:"failed",event:$event}'
    ;;

  complete)
    PROJECT_ROOT=$(canonical_project_root "$PROJECT_ROOT_ARG")
    resolve_run_root
    bash "$SCRIPT_DIR/team-run-state.sh" update --run-root "$RUN_ROOT" \
      --status completed ${EVENT_TEXT:+--event "$EVENT_TEXT"} >/dev/null \
      || fail_diag 'run state update failed'
    jq -n --arg run_root "$RUN_ROOT" --arg event "$EVENT_TEXT" \
      '{schema_version:1,run_root:$run_root,status:"completed",event:$event}'
    ;;

  summary)
    PROJECT_ROOT=$(canonical_project_root "$PROJECT_ROOT_ARG")
    resolve_run_root
    bash "$SCRIPT_DIR/team-run-state.sh" summary --run-root "$RUN_ROOT" \
      || fail_diag 'summary failed'
    ;;
esac
